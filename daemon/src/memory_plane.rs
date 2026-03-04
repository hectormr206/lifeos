//! Memory Plane - encrypted local contextual memory storage.
//!
//! Provides a local, encrypted memory store for assistant context:
//! - persistent notes/events
//! - filtered listing and lightweight search
//! - MCP-friendly context export payload

use aes_gcm_siv::aead::{Aead, KeyInit};
use aes_gcm_siv::{Aes256GcmSiv, Nonce};
use anyhow::{Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

const STATE_FILE: &str = "memory_plane_state.json";
const DEFAULT_MEMORY_KEY: &str = "lifeos-memory-local-key";
const MAX_CONTENT_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryEntry {
    pub entry_id: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub kind: String,
    pub scope: String,
    pub tags: Vec<String>,
    pub source: String,
    pub importance: u8,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemorySearchResult {
    pub entry: MemoryEntry,
    pub score: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MemoryStats {
    pub total_entries: usize,
    pub by_kind: BTreeMap<String, usize>,
    pub by_scope: BTreeMap<String, usize>,
    pub last_updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncryptedMemoryEntry {
    entry_id: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    kind: String,
    scope: String,
    tags: Vec<String>,
    source: String,
    importance: u8,
    nonce_b64: String,
    ciphertext_b64: String,
    plaintext_sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MemoryPlaneState {
    entries: Vec<EncryptedMemoryEntry>,
}

pub struct MemoryPlaneManager {
    data_dir: PathBuf,
    state: Arc<RwLock<MemoryPlaneState>>,
}

impl MemoryPlaneManager {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        Ok(Self {
            data_dir,
            state: Arc::new(RwLock::new(MemoryPlaneState::default())),
        })
    }

    pub async fn initialize(&self) -> Result<()> {
        self.load_state().await
    }

    pub async fn add_entry(
        &self,
        kind: &str,
        scope: &str,
        tags: &[String],
        source: Option<&str>,
        importance: u8,
        content: &str,
    ) -> Result<MemoryEntry> {
        let kind = normalize_non_empty(kind).context("kind is required")?;
        let scope = normalize_non_empty(scope).context("scope is required")?;
        if importance > 100 {
            anyhow::bail!("importance must be in range 0..=100");
        }

        let content = content.trim();
        if content.is_empty() {
            anyhow::bail!("content is required");
        }
        if content.len() > MAX_CONTENT_BYTES {
            anyhow::bail!("content too large (max {} bytes)", MAX_CONTENT_BYTES);
        }

        let normalized_tags = normalize_tags(tags);
        let source = normalize_non_empty(source.unwrap_or("cli://life/memory"))
            .unwrap_or_else(|| "cli://life/memory".to_string());
        let now = Utc::now();
        let (nonce_b64, ciphertext_b64, plaintext_sha256) = encrypt_content(content)?;
        let record = EncryptedMemoryEntry {
            entry_id: format!("mem-{}", Uuid::new_v4()),
            created_at: now,
            updated_at: now,
            kind,
            scope,
            tags: normalized_tags,
            source,
            importance,
            nonce_b64,
            ciphertext_b64,
            plaintext_sha256,
        };

        {
            let mut state = self.state.write().await;
            state.entries.push(record.clone());
        }
        self.save_state().await?;

        self.decrypt_record(&record)
    }

    pub async fn list_entries(
        &self,
        limit: usize,
        scope: Option<&str>,
        tag: Option<&str>,
    ) -> Result<Vec<MemoryEntry>> {
        let limit = limit.max(1).min(500);
        let scope = scope
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        let tag = tag
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());

        let entries = {
            let state = self.state.read().await;
            state.entries.clone()
        };

        let mut out = Vec::new();
        for enc in entries.iter().rev() {
            if let Some(ref scope_filter) = scope {
                if enc.scope.to_lowercase() != *scope_filter {
                    continue;
                }
            }
            if let Some(ref tag_filter) = tag {
                if !enc
                    .tags
                    .iter()
                    .any(|t| t.eq_ignore_ascii_case(tag_filter.as_str()))
                {
                    continue;
                }
            }
            out.push(self.decrypt_record(enc)?);
            if out.len() >= limit {
                break;
            }
        }
        Ok(out)
    }

    pub async fn search_entries(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
    ) -> Result<Vec<MemorySearchResult>> {
        let query = normalize_non_empty(query).context("query is required")?;
        let query_lc = query.to_lowercase();
        let scope = scope
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        let limit = limit.max(1).min(100);

        let entries = {
            let state = self.state.read().await;
            state.entries.clone()
        };

        let mut scored = Vec::new();
        for enc in entries {
            if let Some(ref scope_filter) = scope {
                if enc.scope.to_lowercase() != *scope_filter {
                    continue;
                }
            }
            let entry = self.decrypt_record(&enc)?;
            let score = lexical_score(&query_lc, &entry);
            if score > 0.0 {
                scored.push(MemorySearchResult { entry, score });
            }
        }

        scored.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        scored.truncate(limit);
        Ok(scored)
    }

    pub async fn delete_entry(&self, entry_id: &str) -> Result<bool> {
        let entry_id = normalize_non_empty(entry_id).context("entry_id is required")?;
        let mut state = self.state.write().await;
        let before = state.entries.len();
        state.entries.retain(|e| e.entry_id != entry_id);
        let deleted = state.entries.len() != before;
        drop(state);
        if deleted {
            self.save_state().await?;
        }
        Ok(deleted)
    }

    pub async fn stats(&self) -> MemoryStats {
        let state = self.state.read().await;
        let mut stats = MemoryStats {
            total_entries: state.entries.len(),
            ..MemoryStats::default()
        };

        for entry in &state.entries {
            *stats.by_kind.entry(entry.kind.clone()).or_insert(0) += 1;
            *stats.by_scope.entry(entry.scope.clone()).or_insert(0) += 1;
            stats.last_updated_at = match stats.last_updated_at {
                Some(ts) if ts > entry.updated_at => Some(ts),
                _ => Some(entry.updated_at),
            };
        }

        stats
    }

    pub async fn mcp_context(&self, query: &str, limit: usize) -> Result<serde_json::Value> {
        let results = self.search_entries(query, limit, None).await?;
        let resources = results
            .iter()
            .map(|r| {
                serde_json::json!({
                    "uri": format!("memory://{}", r.entry.entry_id),
                    "name": format!("{} [{}]", r.entry.kind, r.entry.scope),
                    "mimeType": "text/plain",
                    "score": r.score,
                    "text": r.entry.content,
                    "metadata": {
                        "tags": r.entry.tags,
                        "importance": r.entry.importance,
                        "source": r.entry.source,
                        "created_at": r.entry.created_at,
                    }
                })
            })
            .collect::<Vec<_>>();

        Ok(serde_json::json!({
            "protocol": "mcp-memory-context/v1",
            "query": query,
            "resources": resources,
            "count": results.len(),
        }))
    }

    async fn load_state(&self) -> Result<()> {
        let path = self.data_dir.join(STATE_FILE);
        if !path.exists() {
            return Ok(());
        }
        let raw = tokio::fs::read_to_string(&path)
            .await
            .with_context(|| format!("Failed to read {}", path.display()))?;
        let parsed: MemoryPlaneState = serde_json::from_str(&raw)
            .with_context(|| format!("Failed to parse {}", path.display()))?;
        *self.state.write().await = parsed;
        Ok(())
    }

    async fn save_state(&self) -> Result<()> {
        tokio::fs::create_dir_all(&self.data_dir).await?;
        let snapshot = self.state.read().await.clone();
        let serialized = serde_json::to_string_pretty(&snapshot)?;
        let path = self.data_dir.join(STATE_FILE);
        tokio::fs::write(&path, serialized)
            .await
            .with_context(|| format!("Failed to write {}", path.display()))?;
        Ok(())
    }

    fn decrypt_record(&self, record: &EncryptedMemoryEntry) -> Result<MemoryEntry> {
        let content = decrypt_content(record)?;
        Ok(MemoryEntry {
            entry_id: record.entry_id.clone(),
            created_at: record.created_at,
            updated_at: record.updated_at,
            kind: record.kind.clone(),
            scope: record.scope.clone(),
            tags: record.tags.clone(),
            source: record.source.clone(),
            importance: record.importance,
            content,
        })
    }
}

fn normalize_non_empty(input: &str) -> Option<String> {
    let value = input.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn normalize_tags(tags: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for tag in tags {
        let value = tag.trim().to_lowercase();
        if value.is_empty() {
            continue;
        }
        if seen.insert(value.clone()) {
            normalized.push(value);
        }
    }
    normalized
}

fn cipher() -> Result<Aes256GcmSiv> {
    let passphrase = std::env::var("LIFEOS_MEMORY_KEY")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_MEMORY_KEY.to_string());
    let key = Sha256::digest(passphrase.as_bytes());
    Aes256GcmSiv::new_from_slice(&key)
        .map_err(|e| anyhow::anyhow!("failed to initialize memory cipher: {}", e))
}

fn encrypt_content(content: &str) -> Result<(String, String, String)> {
    let cipher = cipher()?;
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, content.as_bytes())
        .map_err(|e| anyhow::anyhow!("failed to encrypt memory entry: {}", e))?;
    let digest = Sha256::digest(content.as_bytes());
    Ok((
        B64.encode(nonce_bytes),
        B64.encode(ciphertext),
        format!("{:x}", digest),
    ))
}

fn decrypt_content(record: &EncryptedMemoryEntry) -> Result<String> {
    let cipher = cipher()?;
    let nonce_bytes = B64
        .decode(record.nonce_b64.as_bytes())
        .context("invalid nonce encoding")?;
    if nonce_bytes.len() != 12 {
        anyhow::bail!("invalid nonce length");
    }
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = B64
        .decode(record.ciphertext_b64.as_bytes())
        .context("invalid ciphertext encoding")?;
    let plaintext = cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|e| anyhow::anyhow!("failed to decrypt memory entry: {}", e))?;
    let plaintext = String::from_utf8(plaintext).context("memory plaintext is not utf-8")?;

    let digest = format!("{:x}", Sha256::digest(plaintext.as_bytes()));
    if digest != record.plaintext_sha256 {
        anyhow::bail!("memory digest validation failed");
    }
    Ok(plaintext)
}

fn lexical_score(query: &str, entry: &MemoryEntry) -> f64 {
    let query_tokens = tokenize(query);
    if query_tokens.is_empty() {
        return 0.0;
    }

    let corpus = format!(
        "{} {} {} {} {}",
        entry.kind,
        entry.scope,
        entry.tags.join(" "),
        entry.source,
        entry.content
    )
    .to_lowercase();
    let corpus_tokens = tokenize(&corpus);
    if corpus_tokens.is_empty() {
        return 0.0;
    }

    let matches = query_tokens
        .iter()
        .filter(|token| corpus_tokens.contains(*token))
        .count();
    let mut score = matches as f64 / query_tokens.len() as f64;
    if corpus.contains(query) {
        score += 0.35;
    }
    score += (entry.importance as f64 / 100.0) * 0.1;
    score.min(1.0)
}

fn tokenize(input: &str) -> HashSet<String> {
    input
        .split(|c: char| !c.is_alphanumeric())
        .filter_map(|t| {
            let token = t.trim().to_lowercase();
            if token.is_empty() {
                None
            } else {
                Some(token)
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{}-{}", prefix, Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn add_and_list_roundtrip_decrypts() {
        let dir = temp_dir("memory-plane-roundtrip");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();

        mgr.add_entry(
            "note",
            "user",
            &["phase2".to_string(), "todo".to_string()],
            Some("test://suite"),
            80,
            "LifeOS memory plane should persist encrypted entries.",
        )
        .await
        .unwrap();

        let entries = mgr
            .list_entries(10, Some("user"), Some("phase2"))
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert!(entries[0].content.contains("persist encrypted entries"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn search_ranks_relevant_entries() {
        let dir = temp_dir("memory-plane-search");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();

        mgr.add_entry(
            "note",
            "user",
            &["meeting".to_string()],
            None,
            20,
            "Prepare release retrospective and share risk list.",
        )
        .await
        .unwrap();
        mgr.add_entry(
            "note",
            "user",
            &["infra".to_string()],
            None,
            95,
            "Fix runtime approval mode for run-until-done automation.",
        )
        .await
        .unwrap();

        let hits = mgr
            .search_entries("runtime approval automation", 5, Some("user"))
            .await
            .unwrap();
        assert!(!hits.is_empty());
        assert!(hits[0].entry.content.contains("run-until-done"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn state_file_keeps_ciphertext_not_plaintext() {
        let dir = temp_dir("memory-plane-ciphertext");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.add_entry("note", "user", &[], None, 50, "plain text sentinel 123")
            .await
            .unwrap();

        let raw = std::fs::read_to_string(dir.join(STATE_FILE)).unwrap();
        assert!(!raw.contains("plain text sentinel 123"));
        assert!(raw.contains("ciphertext_b64"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn delete_entry_removes_record() {
        let dir = temp_dir("memory-plane-delete");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        let created = mgr
            .add_entry("note", "user", &[], None, 10, "delete me")
            .await
            .unwrap();

        let deleted = mgr.delete_entry(&created.entry_id).await.unwrap();
        assert!(deleted);
        let entries = mgr.list_entries(10, None, None).await.unwrap();
        assert!(entries.is_empty());

        std::fs::remove_dir_all(dir).ok();
    }
}
