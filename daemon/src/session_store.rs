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
use std::sync::Arc;
use tokio::sync::RwLock;

const MAX_TOOL_RESULT_CHARS: usize = 2000;
const SESSION_TTL_HOURS: u64 = 72;
const COMPACTION_THRESHOLD: usize = 20;

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

    /// Create a session key for Telegram DM
    pub fn telegram_dm(chat_id: i64) -> Self {
        Self::new("telegram", "dm", &chat_id.to_string())
    }

    /// Create a session key for Telegram group
    pub fn telegram_group(chat_id: i64) -> Self {
        Self::new("telegram", "group", &chat_id.to_string())
    }

    /// Create a session key for voice interaction
    pub fn voice(session_id: &str) -> Self {
        Self::new("voice", "dm", session_id)
    }

    /// Create a session key for WhatsApp
    pub fn whatsapp(phone: &str) -> Self {
        Self::new("whatsapp", "dm", phone)
    }

    /// Create a session key for Matrix
    pub fn matrix(room_id: &str) -> Self {
        Self::new("matrix", "room", room_id)
    }

    /// Create a session key for Signal
    pub fn signal(phone: &str) -> Self {
        Self::new("signal", "dm", phone)
    }

    /// Create a session key for Slack
    pub fn slack(channel_id: &str) -> Self {
        Self::new("slack", "channel", channel_id)
    }

    /// Create a session key for Discord
    pub fn discord(channel_id: &str) -> Self {
        Self::new("discord", "channel", channel_id)
    }

    /// Create a session key for SimpleX.
    ///
    /// `contact_id` is the stable SimpleX contact identifier — typically the
    /// `localDisplayName` from the CLI, which persists across daemon restarts.
    /// One session per contact guarantees durable, isolated replay history.
    pub fn simplex(contact_id: &str) -> Self {
        Self::new("simplex", "dm", contact_id)
    }

    /// Create a session key for CLI
    pub fn cli() -> Self {
        Self::new("cli", "local", "default")
    }

    /// Canonical string representation: `agent:axi:<channel>:<scope>:<peer_id>`
    pub fn as_canonical(&self) -> String {
        format!(
            "agent:{}:{}:{}:{}",
            self.agent, self.channel, self.scope, self.peer_id
        )
    }

    /// Generate a filesystem-safe session directory name.
    ///
    /// `peer_id` may be attacker-controlled (SimpleX `localDisplayName`,
    /// WhatsApp phone alias, Matrix room alias, etc.) so we sanitize it
    /// defensively: strip path separators, parent-dir traversal tokens,
    /// NUL / control chars, and leading `-` (which could be mis-parsed as
    /// a CLI flag by downstream tools). If sanitization meaningfully
    /// changes the input OR leaves it empty, we fall back to a short
    /// SHA-256 hex digest of the raw peer_id so the directory name is
    /// still stable and unique per contact.
    pub fn dir_name(&self) -> String {
        let sanitized = sanitize_peer_id(&self.peer_id);
        format!("{}_{}_{}", self.channel, self.scope, sanitized)
    }
}

/// Sanitize a `peer_id` so it can safely be joined to a base directory.
///
/// - Replaces any `/`, `\`, `\0`, or ASCII control char with `_`.
/// - Rejects `.` / `..` components.
/// - Strips leading `-` (defense against tools parsing it as a flag).
/// - On any meaningful change OR empty result, returns a short SHA-256
///   hex digest of the raw input so collisions are still rare.
pub(crate) fn sanitize_peer_id(raw: &str) -> String {
    // Fast path: known-safe chars only.
    let safe = raw
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '+' | '=' | ':' | '@'))
        && !raw.is_empty()
        && raw != "."
        && raw != ".."
        && !raw.contains("..")
        && !raw.starts_with('-');

    if safe {
        return raw.to_string();
    }

    // Unsafe — hash it. Short digest (first 16 hex chars = 64 bits) is
    // plenty given the per-channel namespace.
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(raw.as_bytes());
    let digest = hasher.finalize();
    let hex: String = digest
        .iter()
        .take(8)
        .map(|b| format!("{:02x}", b))
        .collect();
    format!("sanitized_{}", hex)
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

impl TranscriptTurn {
    /// Create a new transcript turn with the current timestamp.
    pub fn new(role: &str, content: &str, channel: &str) -> Self {
        Self {
            role: role.to_string(),
            content: content.to_string(),
            channel: channel.to_string(),
            timestamp: Utc::now(),
            tool_name: None,
            tool_result: None,
        }
    }
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
        tokio::fs::write(&meta_path, &content).await?;
        // Restrict metadata to owner-only (contains session keys and timestamps).
        Self::set_file_permissions_0o600(&meta_path);

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

        // Future: encrypt transcript lines at rest (AES-256-GCM-SIV pattern
        // from memory_plane.rs). Requires updating load_recent_turns() and
        // compact_session() to decrypt.
        // Deferred because it touches the read path in load_recent_turns() and
        // compact_session(). File permissions (0o600) provide baseline protection.

        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&transcript_path)
            .await?;
        file.write_all(line.as_bytes()).await?;
        // Restrict transcript to owner-only (contains conversation content).
        Self::set_file_permissions_0o600(&transcript_path);

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
                Self::set_file_permissions_0o600(&meta_path);
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
        let cutoff = Utc::now() - chrono::Duration::hours(24);
        let mut turns: Vec<TranscriptTurn> = content
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str::<TranscriptTurn>(l).ok())
            .filter(|t| t.timestamp > cutoff)
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
                Self::set_file_permissions_0o600(&meta_path);
            }
        }

        Ok(())
    }

    /// Archive a legacy SimpleX session that was stored under the synthetic
    /// telegram-dm magic chat_id.
    ///
    /// Historical note: a previous build stored ALL SimpleX conversations
    /// under a single synthetic key derived from `SIMPLEX_CHAT_ID`. If the
    /// user interacted with more than one SimpleX contact before upgrading,
    /// that directory contains MIXED transcripts from multiple people.
    /// Rebinding it to `last_known_contact()` would mis-attribute other
    /// contacts' messages to whoever happened to be the most recent one —
    /// a privacy bug.
    ///
    /// Instead, we move the legacy directory to
    /// `<base>/.legacy_archive/simplex_telegram_dm_<magic>_<timestamp>/`
    /// and drop it from the in-memory index. The user retains the data
    /// (it's not deleted) but it's no longer replayed into any live
    /// conversation. A Rioplatense info message is logged.
    ///
    /// Returns `Ok(true)` if an archive happened, `Ok(false)` otherwise.
    pub async fn archive_simplex_legacy_session(&self, legacy_chat_id: i64) -> Result<bool> {
        let legacy = SessionKey::new("telegram", "dm", &legacy_chat_id.to_string());
        let legacy_dir = self.base_dir.join(legacy.dir_name());

        if !legacy_dir.exists() {
            return Ok(false);
        }

        let archive_root = self.base_dir.join(".legacy_archive");
        tokio::fs::create_dir_all(&archive_root)
            .await
            .context("creating .legacy_archive dir")?;

        let ts = Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
        let dest = archive_root.join(format!(
            "simplex_telegram_dm_{}_{}",
            legacy_chat_id, ts
        ));

        tokio::fs::rename(&legacy_dir, &dest)
            .await
            .with_context(|| {
                format!(
                    "archiving legacy simplex session {} -> {}",
                    legacy_dir.display(),
                    dest.display()
                )
            })?;

        // Drop the legacy entry from the in-memory index so it doesn't get
        // replayed into any live conversation.
        let mut sessions = self.sessions.write().await;
        sessions.remove(&legacy.as_canonical());
        drop(sessions);

        info!(
            "[session_store] Archivé la sesión SimpleX previa (chat_id={}) en {}. \
             La historia pre-upgrade tenía mensajes mezclados de varios contactos \
             y no puedo atribuírsela a uno solo sin arriesgar tu privacidad, loco.",
            legacy_chat_id,
            dest.display()
        );
        Ok(true)
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

    /// Set file permissions to 0o600 (owner read/write only).
    /// Best-effort: failures are silently ignored since the daemon may
    /// run on non-Unix or permission-restricted filesystems.
    #[cfg(unix)]
    fn set_file_permissions_0o600(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }

    #[cfg(not(unix))]
    fn set_file_permissions_0o600(_path: &std::path::Path) {}

    /// List all active sessions.
    pub async fn list_sessions(&self) -> Vec<SessionMetadata> {
        let sessions = self.sessions.read().await;
        sessions.values().cloned().collect()
    }

    /// Compact a session's transcript by summarizing old turns via LLM.
    /// Keeps the last `KEEP_RECENT` turns verbatim and summarizes everything before.
    pub async fn compact_session(
        &self,
        key: &SessionKey,
        router: &Arc<RwLock<crate::llm_router::LlmRouter>>,
    ) -> Result<()> {
        const KEEP_RECENT: usize = 10;

        let all_turns = self.load_recent_turns(key, 9999).await?;
        if all_turns.len() < COMPACTION_THRESHOLD {
            return Ok(()); // Not enough turns to compact
        }

        let old_turns = &all_turns[..all_turns.len().saturating_sub(KEEP_RECENT)];

        // Build text from old turns for summarization
        let mut old_text = String::new();
        for turn in old_turns {
            old_text.push_str(&format!("[{}] {}\n", turn.role, turn.content));
        }

        // Summarize via LLM
        let prompt = format!(
            "Resume esta conversacion en maximo 500 palabras, conservando: \
             decisiones tomadas, datos importantes, contexto del usuario, \
             y cualquier compromiso o tarea pendiente:\n\n{}",
            crate::str_utils::truncate_bytes_safe(&old_text, 8000)
        );

        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
            task_type: None,
        };

        let router_guard = router.read().await;
        let response = router_guard.chat(&request).await?;
        drop(router_guard);

        // Save summary
        self.set_compaction_summary(key, response.text).await?;

        // Rewrite transcript with only recent turns
        let recent_turns = &all_turns[all_turns.len().saturating_sub(KEEP_RECENT)..];
        let session_dir = self.base_dir.join(key.dir_name());
        let transcript_path = session_dir.join("transcript.jsonl");

        let mut content = String::new();
        for turn in recent_turns {
            content.push_str(&serde_json::to_string(turn)?);
            content.push('\n');
        }
        tokio::fs::write(&transcript_path, content).await?;
        Self::set_file_permissions_0o600(&transcript_path);

        info!(
            "[session_store] Compacted session {}: {} turns -> {} recent + summary",
            key,
            all_turns.len(),
            recent_turns.len()
        );

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir_name_with(peer: &str) -> String {
        SessionKey::new("simplex", "dm", peer).dir_name()
    }

    #[test]
    fn dir_name_rejects_path_traversal() {
        let d = dir_name_with("../..");
        assert!(!d.contains(".."), "must strip parent-dir tokens: {}", d);
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_rejects_absolute_and_slash() {
        let d = dir_name_with("/tmp/x");
        assert!(!d.contains('/'), "must strip path separators: {}", d);
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_rejects_nul_byte() {
        let d = dir_name_with("evil\0name");
        assert!(!d.contains('\0'));
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_rejects_dot_dot() {
        let d = dir_name_with("..");
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_rejects_empty() {
        let d = dir_name_with("");
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_rejects_leading_dash() {
        let d = dir_name_with("-rf");
        assert!(d.starts_with("simplex_dm_sanitized_"));
    }

    #[test]
    fn dir_name_accepts_normal_contact() {
        let d = dir_name_with("alice_42");
        assert_eq!(d, "simplex_dm_alice_42");
    }

    #[test]
    fn dir_name_accepts_numeric_chat_id() {
        let d = SessionKey::telegram_dm(316014621).dir_name();
        assert_eq!(d, "telegram_dm_316014621");
    }
}
