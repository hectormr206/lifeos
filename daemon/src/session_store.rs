//! Session Store — durable conversation sessions with JSONL transcripts.
//!
//! Each conversation (Telegram DM, voice session, CLI) gets a stable session
//! with persistent transcript. Sessions survive daemon restarts.
//!
//! Session keys follow the format: `agent:axi:<channel>:<scope>:<peer_id>`
//! e.g., `agent:axi:telegram:dm:316014621`

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::sync::RwLock;

const MAX_TOOL_RESULT_CHARS: usize = 2000;
const SESSION_TTL_HOURS: u64 = 72;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionKey {
    pub agent: String,   // "axi"
    pub channel: String, // "telegram", "voice", "cli", "whatsapp", "matrix", "signal"
    pub scope: String,   // "dm", "group"
    pub peer_id: String, // channel-specific peer identifier
}

impl SessionKey {
    pub fn new(channel: &str, scope: &str, peer_id: &str) -> Self {
        Self {
            agent: "axi".to_string(),
            channel: channel.to_string(),
            scope: scope.to_string(),
            peer_id: peer_id.to_string(),
        }
    }

    /// Canonical string representation: `agent:axi:<channel>:<scope>:<peer_id>`
    pub fn as_canonical(&self) -> String {
        format!(
            "agent:{}:{}:{}:{}",
            self.agent, self.channel, self.scope, self.peer_id
        )
    }

    /// Generate a filesystem-safe session directory name.
    pub fn dir_name(&self) -> String {
        format!("{}_{}_{}", self.channel, self.scope, self.peer_id)
    }
}

impl std::fmt::Display for SessionKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_canonical())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptTurn {
    pub role: String, // "user", "assistant", "tool"
    pub content: String,
    pub channel: String,
    pub timestamp: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_result: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMetadata {
    pub session_key: String,
    pub created_at: DateTime<Utc>,
    pub last_active_at: DateTime<Utc>,
    pub last_channel: String,
    pub last_peer_id: String,
    pub turn_count: usize,
    pub compacted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compaction_summary: Option<String>,
}

pub struct SessionStore {
    base_dir: PathBuf,
    sessions: RwLock<HashMap<String, SessionMetadata>>,
}

impl SessionStore {
    pub fn new(data_dir: &Path) -> Self {
        let base_dir = data_dir.join("sessions");
        Self {
            base_dir,
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// Initialize the store -- load existing session metadata from disk.
    pub async fn init(&self) -> Result<()> {
        tokio::fs::create_dir_all(&self.base_dir)
            .await
            .context("creating sessions directory")?;

        let mut sessions = self.sessions.write().await;
        let mut dir = tokio::fs::read_dir(&self.base_dir).await?;

        while let Some(entry) = dir.next_entry().await? {
            if entry.file_type().await?.is_dir() {
                let meta_path = entry.path().join("metadata.json");
                if let Ok(content) = tokio::fs::read_to_string(&meta_path).await {
                    match serde_json::from_str::<SessionMetadata>(&content) {
                        Ok(meta) => {
                            sessions.insert(meta.session_key.clone(), meta);
                        }
                        Err(e) => {
                            warn!(
                                "[session_store] Corrupt metadata in {}: {}",
                                meta_path.display(),
                                e
                            );
                        }
                    }
                }
            }
        }

        info!(
            "[session_store] Loaded {} sessions from disk",
            sessions.len()
        );
        Ok(())
    }

    /// Get or create a session for the given key.
    pub async fn get_or_create(&self, key: &SessionKey) -> Result<SessionMetadata> {
        let key_str = key.as_canonical();

        {
            let sessions = self.sessions.read().await;
            if let Some(meta) = sessions.get(&key_str) {
                return Ok(meta.clone());
            }
        }

        // Create new session
        let meta = SessionMetadata {
            session_key: key_str.clone(),
            created_at: Utc::now(),
            last_active_at: Utc::now(),
            last_channel: key.channel.clone(),
            last_peer_id: key.peer_id.clone(),
            turn_count: 0,
            compacted: false,
            compaction_summary: None,
        };

        let session_dir = self.base_dir.join(key.dir_name());
        tokio::fs::create_dir_all(&session_dir).await?;

        let meta_path = session_dir.join("metadata.json");
        let content = serde_json::to_string_pretty(&meta)?;
        tokio::fs::write(&meta_path, content).await?;

        let mut sessions = self.sessions.write().await;
        sessions.insert(key_str, meta.clone());

        info!("[session_store] Created new session: {}", key);
        Ok(meta)
    }

    /// Append a turn to the session transcript (JSONL format).
    pub async fn append_turn(&self, key: &SessionKey, turn: TranscriptTurn) -> Result<()> {
        let session_dir = self.base_dir.join(key.dir_name());
        tokio::fs::create_dir_all(&session_dir).await?;

        let transcript_path = session_dir.join("transcript.jsonl");

        // Truncate tool results if too long
        let mut turn = turn;
        if let Some(ref result) = turn.tool_result {
            if result.len() > MAX_TOOL_RESULT_CHARS {
                turn.tool_result = Some(format!(
                    "{}... [truncated, {} chars total]",
                    &result[..MAX_TOOL_RESULT_CHARS],
                    result.len()
                ));
            }
        }

        let line = serde_json::to_string(&turn)? + "\n";

        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&transcript_path)
            .await?;
        file.write_all(line.as_bytes()).await?;

        // Update metadata
        let key_str = key.as_canonical();
        let mut sessions = self.sessions.write().await;
        if let Some(meta) = sessions.get_mut(&key_str) {
            meta.last_active_at = Utc::now();
            meta.last_channel = key.channel.clone();
            meta.last_peer_id = key.peer_id.clone();
            meta.turn_count += 1;

            // Save updated metadata
            let meta_path = session_dir.join("metadata.json");
            if let Ok(content) = serde_json::to_string_pretty(meta) {
                let _ = tokio::fs::write(&meta_path, content).await;
            }
        }

        Ok(())
    }

    /// Load recent turns from a session transcript.
    pub async fn load_recent_turns(
        &self,
        key: &SessionKey,
        max_turns: usize,
    ) -> Result<Vec<TranscriptTurn>> {
        let transcript_path = self.base_dir.join(key.dir_name()).join("transcript.jsonl");

        if !transcript_path.exists() {
            return Ok(Vec::new());
        }

        let content = tokio::fs::read_to_string(&transcript_path).await?;
        let mut turns: Vec<TranscriptTurn> = content
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();

        // Return only the most recent turns
        if turns.len() > max_turns {
            turns = turns[turns.len() - max_turns..].to_vec();
        }

        Ok(turns)
    }

    /// Get the compaction summary for a session (if compacted).
    pub async fn get_compaction_summary(&self, key: &SessionKey) -> Option<String> {
        let sessions = self.sessions.read().await;
        sessions
            .get(&key.as_canonical())
            .and_then(|m| m.compaction_summary.clone())
    }

    /// Mark a session as compacted with the given summary.
    pub async fn set_compaction_summary(&self, key: &SessionKey, summary: String) -> Result<()> {
        let key_str = key.as_canonical();
        let session_dir = self.base_dir.join(key.dir_name());

        let mut sessions = self.sessions.write().await;
        if let Some(meta) = sessions.get_mut(&key_str) {
            meta.compacted = true;
            meta.compaction_summary = Some(summary);

            let meta_path = session_dir.join("metadata.json");
            if let Ok(content) = serde_json::to_string_pretty(meta) {
                let _ = tokio::fs::write(&meta_path, content).await;
            }
        }

        Ok(())
    }

    /// Prune sessions older than TTL from the in-memory index.
    /// Transcript files on disk are kept for potential recovery;
    /// the `storage_housekeeping` module handles disk cleanup.
    pub async fn prune_stale_sessions(&self) -> Result<usize> {
        let cutoff = Utc::now() - chrono::Duration::hours(SESSION_TTL_HOURS as i64);
        let mut to_remove = Vec::new();

        {
            let sessions = self.sessions.read().await;
            for (key, meta) in sessions.iter() {
                if meta.last_active_at < cutoff {
                    to_remove.push(key.clone());
                }
            }
        }

        let count = to_remove.len();
        if count > 0 {
            let mut sessions = self.sessions.write().await;
            for key in &to_remove {
                sessions.remove(key);
            }
            info!("[session_store] Pruned {} stale sessions", count);
        }

        Ok(count)
    }

    /// List all active sessions.
    pub async fn list_sessions(&self) -> Vec<SessionMetadata> {
        let sessions = self.sessions.read().await;
        sessions.values().cloned().collect()
    }
}
