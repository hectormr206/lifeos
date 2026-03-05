//! Memory Plane - encrypted local contextual memory storage.
//!
//! Provides a local, encrypted memory store for assistant context:
//! - persistent notes/events
//! - filtered listing and lightweight search
//! - MCP-friendly context export payload

use crate::ai::AiManager;
use aes_gcm_siv::aead::{Aead, KeyInit};
use aes_gcm_siv::{Aes256GcmSiv, Nonce};
use anyhow::{Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

const STATE_FILE: &str = "memory_plane_state.json";
const DEFAULT_MEMORY_KEY: &str = "lifeos-memory-local-key";
const MAX_CONTENT_BYTES: usize = 64 * 1024;
const DB_FILE: &str = "memory.db";
const EMBEDDING_DIM: usize = 768;

const SCHEMA: &str = r#"
-- Metadata table for encrypted entries
CREATE TABLE IF NOT EXISTS memory_entries (
    entry_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    kind TEXT NOT NULL,
    scope TEXT NOT NULL,
    tags TEXT NOT NULL,
    source TEXT NOT NULL,
    importance INTEGER NOT NULL,
    nonce_b64 TEXT NOT NULL,
    ciphertext_b64 TEXT NOT NULL,
    plaintext_sha256 TEXT NOT NULL,
    embedding_source TEXT NOT NULL DEFAULT 'fallback'
);

-- Vector search table (sqlite-vec)
CREATE VIRTUAL TABLE IF NOT EXISTS memory_embeddings USING vec0(
    entry_id TEXT PRIMARY KEY,
    embedding FLOAT[768]
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_memory_kind ON memory_entries(kind);
CREATE INDEX IF NOT EXISTS idx_memory_scope ON memory_entries(scope);
CREATE INDEX IF NOT EXISTS idx_memory_created ON memory_entries(created_at);
"#;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemorySearchMode {
    Lexical,
    Semantic,
    Hybrid,
}

impl MemorySearchMode {
    pub fn parse(value: Option<&str>) -> Self {
        match value
            .map(|v| v.trim().to_lowercase())
            .unwrap_or_else(|| "hybrid".to_string())
            .as_str()
        {
            "lexical" => Self::Lexical,
            "semantic" => Self::Semantic,
            _ => Self::Hybrid,
        }
    }
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

#[derive(Clone)]
pub struct MemoryPlaneManager {
    data_dir: PathBuf,
    db_path: PathBuf,
    ai_manager: Option<Arc<AiManager>>,
}

impl MemoryPlaneManager {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        Self::with_ai_manager(data_dir, None)
    }

    pub fn with_ai_manager(data_dir: PathBuf, ai_manager: Option<Arc<AiManager>>) -> Result<Self> {
        std::fs::create_dir_all(&data_dir).context("Failed to create memory data directory")?;

        let db_path = data_dir.join(DB_FILE);
        let db = Self::open_db(&db_path)?;

        db.execute_batch(SCHEMA)
            .context("Failed to initialize memory schema")?;

        Ok(Self {
            data_dir,
            db_path,
            ai_manager,
        })
    }

    fn open_db(db_path: &Path) -> Result<Connection> {
        unsafe {
            type SqliteAutoExtInit = unsafe extern "C" fn(
                *mut rusqlite::ffi::sqlite3,
                *mut *mut i8,
                *const rusqlite::ffi::sqlite3_api_routines,
            ) -> i32;
            rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute::<
                *const (),
                SqliteAutoExtInit,
            >(
                sqlite_vec::sqlite3_vec_init as *const (),
            )));
        }
        let db = Connection::open(db_path).context("Failed to open memory database")?;
        Ok(db)
    }

    pub async fn initialize(&self) -> Result<()> {
        self.migrate_from_json().await
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
        let entry_id = format!("mem-{}", Uuid::new_v4());

        let (embedding, embedding_source) = self.generate_embedding(content).await;

        let db_path = self.db_path.clone();
        let entry_id_clone = entry_id.clone();
        let kind_clone = kind.clone();
        let scope_clone = scope.clone();
        let tags_json = serde_json::to_string(&normalized_tags)?;
        let source_clone = source.clone();
        let now_rfc3339 = now.to_rfc3339();
        let embedding_bytes: Vec<u8> = embedding.iter().flat_map(|f| f.to_le_bytes()).collect();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;

            tx.execute(
                "INSERT INTO memory_entries 
                 (entry_id, created_at, updated_at, kind, scope, tags, source, importance, 
                  nonce_b64, ciphertext_b64, plaintext_sha256, embedding_source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    entry_id_clone,
                    now_rfc3339,
                    now_rfc3339,
                    kind_clone,
                    scope_clone,
                    tags_json,
                    source_clone,
                    importance as i32,
                    nonce_b64,
                    ciphertext_b64,
                    plaintext_sha256,
                    embedding_source,
                ],
            )?;

            tx.execute(
                "INSERT INTO memory_embeddings (entry_id, embedding) VALUES (?1, vec_f32(?2))",
                params![entry_id_clone, embedding_bytes],
            )?;

            tx.commit()?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(MemoryEntry {
            entry_id,
            created_at: now,
            updated_at: now,
            kind,
            scope,
            tags: normalized_tags,
            source,
            importance,
            content: content.to_string(),
        })
    }

    async fn generate_embedding(&self, text: &str) -> (Vec<f32>, String) {
        if let Some(ref ai) = self.ai_manager {
            match ai.embed(text).await {
                Ok(resp) if resp.model != "hash-fallback" => {
                    return (resp.embedding, "real".to_string());
                }
                Ok(resp) => {
                    return (resp.embedding, "fallback".to_string());
                }
                Err(e) => {
                    log::warn!("Embedding generation failed: {}", e);
                }
            }
        }

        let embedding = hash_based_embedding_local(text);
        (embedding, "fallback".to_string())
    }

    pub async fn list_entries(
        &self,
        limit: usize,
        scope: Option<&str>,
        tag: Option<&str>,
    ) -> Result<Vec<MemoryEntry>> {
        let limit = limit.clamp(1, 500);
        let scope = scope
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        let tag = tag
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());

        let db_path = self.db_path.clone();

        let entries = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let mut sql = "SELECT entry_id, created_at, updated_at, kind, scope, tags, source, 
                                  importance, nonce_b64, ciphertext_b64, plaintext_sha256 
                           FROM memory_entries"
                .to_string();
            let mut conditions = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(ref s) = scope {
                conditions.push("scope = ?");
                params_vec.push(Box::new(s.clone()));
            }

            if !conditions.is_empty() {
                sql.push_str(" WHERE ");
                sql.push_str(&conditions.join(" AND "));
            }

            sql.push_str(" ORDER BY created_at DESC");
            sql.push_str(&format!(" LIMIT {}", limit));

            let params: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();

            let mut stmt = db.prepare(&sql)?;
            let entries = stmt
                .query_map(params.as_slice(), |row| {
                    let tags_json: String = row.get(5)?;
                    let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();

                    Ok(EncryptedMemoryEntry {
                        entry_id: row.get(0)?,
                        created_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                            .map(|dt| dt.with_timezone(&Utc))
                            .unwrap_or_else(|_| Utc::now()),
                        updated_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(2)?)
                            .map(|dt| dt.with_timezone(&Utc))
                            .unwrap_or_else(|_| Utc::now()),
                        kind: row.get(3)?,
                        scope: row.get(4)?,
                        tags,
                        source: row.get(6)?,
                        importance: row.get::<_, i32>(7)? as u8,
                        nonce_b64: row.get(8)?,
                        ciphertext_b64: row.get(9)?,
                        plaintext_sha256: row.get(10)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;

            Ok::<_, anyhow::Error>(entries)
        })
        .await??;

        let mut out = Vec::new();
        for enc in entries {
            if let Some(ref tag_filter) = tag {
                if !enc
                    .tags
                    .iter()
                    .any(|t| t.eq_ignore_ascii_case(tag_filter.as_str()))
                {
                    continue;
                }
            }
            out.push(decrypt_entry(&enc)?);
        }
        Ok(out)
    }

    pub async fn search_entries(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
    ) -> Result<Vec<MemorySearchResult>> {
        self.search_entries_with_mode(query, limit, scope, MemorySearchMode::Hybrid)
            .await
    }

    pub async fn search_entries_with_mode(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
        mode: MemorySearchMode,
    ) -> Result<Vec<MemorySearchResult>> {
        let query = normalize_non_empty(query).context("query is required")?;
        let query_lc = query.to_lowercase();
        let scope = scope
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        let limit = limit.clamp(1, 100);

        let db_path = self.db_path.clone();
        let ai_manager = self.ai_manager.clone();

        let query_embedding = if let Some(ref ai) = ai_manager {
            match ai.embed(&query_lc).await {
                Ok(resp) => resp.embedding,
                Err(_) => semantic_embedding(&query_lc),
            }
        } else {
            semantic_embedding(&query_lc)
        };

        let query_embedding_bytes: Vec<u8> = query_embedding
            .iter()
            .flat_map(|f: &f32| f.to_le_bytes())
            .collect();

        let results = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            match mode {
                MemorySearchMode::Semantic => {
                    let mut sql = r#"
                        SELECT me.entry_id, me.created_at, me.updated_at, me.kind, me.scope, 
                               me.tags, me.source, me.importance, me.nonce_b64, me.ciphertext_b64, 
                               me.plaintext_sha256, vec_distance_cosine(em.embedding, vec_f32(?)) as score
                        FROM memory_entries me
                        JOIN memory_embeddings em ON me.entry_id = em.entry_id
                    "#.to_string();

                    let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> =
                        vec![Box::new(query_embedding_bytes.clone())];

                    if let Some(ref s) = scope {
                        sql.push_str(" WHERE me.scope = ?");
                        params_vec.push(Box::new(s.clone()));
                    }

                    sql.push_str(" ORDER BY score ASC LIMIT ?");
                    params_vec.push(Box::new(limit as i32));

                    let params: Vec<&dyn rusqlite::ToSql> =
                        params_vec.iter().map(|p| p.as_ref()).collect();

                    let mut stmt = db.prepare(&sql)?;
                    let rows = stmt
                        .query_map(params.as_slice(), |row| {
                            let tags_json: String = row.get(5)?;
                            let tags: Vec<String> =
                                serde_json::from_str(&tags_json).unwrap_or_default();
                            let raw_score: f32 = row.get(11)?;

                            Ok((
                                EncryptedMemoryEntry {
                                    entry_id: row.get(0)?,
                                    created_at:
                                        DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                                            .map(|dt| dt.with_timezone(&Utc))
                                            .unwrap_or_else(|_| Utc::now()),
                                    updated_at:
                                        DateTime::parse_from_rfc3339(&row.get::<_, String>(2)?)
                                            .map(|dt| dt.with_timezone(&Utc))
                                            .unwrap_or_else(|_| Utc::now()),
                                    kind: row.get(3)?,
                                    scope: row.get(4)?,
                                    tags,
                                    source: row.get(6)?,
                                    importance: row.get::<_, i32>(7)? as u8,
                                    nonce_b64: row.get(8)?,
                                    ciphertext_b64: row.get(9)?,
                                    plaintext_sha256: row.get(10)?,
                                },
                                raw_score,
                            ))
                        })?
                        .collect::<Result<Vec<_>, _>>()?;

                    Ok::<_, anyhow::Error>(rows)
                }

                MemorySearchMode::Lexical => {
                    let mut sql = "SELECT entry_id, created_at, updated_at, kind, scope, tags, source, 
                                          importance, nonce_b64, ciphertext_b64, plaintext_sha256 
                                   FROM memory_entries"
                        .to_string();
                    let mut conditions = vec!["ciphertext_b64 LIKE ?"];
                    let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> =
                        vec![Box::new(format!("%{}%", query_lc))];

                    if let Some(ref s) = scope {
                        conditions.push("scope = ?");
                        params_vec.push(Box::new(s.clone()));
                    }

                    sql.push_str(" WHERE ");
                    sql.push_str(&conditions.join(" AND "));
                    sql.push_str(" ORDER BY created_at DESC");

                    let params: Vec<&dyn rusqlite::ToSql> =
                        params_vec.iter().map(|p| p.as_ref()).collect();

                    let mut stmt = db.prepare(&sql)?;
                    let entries = stmt
                        .query_map(params.as_slice(), |row| {
                            let tags_json: String = row.get(5)?;
                            let tags: Vec<String> =
                                serde_json::from_str(&tags_json).unwrap_or_default();

                            Ok(EncryptedMemoryEntry {
                                entry_id: row.get(0)?,
                                created_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                                    .map(|dt| dt.with_timezone(&Utc))
                                    .unwrap_or_else(|_| Utc::now()),
                                updated_at: DateTime::parse_from_rfc3339(&row.get::<_, String>(2)?)
                                    .map(|dt| dt.with_timezone(&Utc))
                                    .unwrap_or_else(|_| Utc::now()),
                                kind: row.get(3)?,
                                scope: row.get(4)?,
                                tags,
                                source: row.get(6)?,
                                importance: row.get::<_, i32>(7)? as u8,
                                nonce_b64: row.get(8)?,
                                ciphertext_b64: row.get(9)?,
                                plaintext_sha256: row.get(10)?,
                            })
                        })?
                        .collect::<Result<Vec<_>, _>>()?;

                    let mut scored = Vec::new();
                    for enc in entries {
                        if let Ok(entry) = decrypt_entry(&enc) {
                            let score = lexical_score(&query_lc, &entry);
                            if score > 0.0 {
                                scored.push((enc, score as f32));
                            }
                        }
                    }

                    Ok(scored)
                }

                MemorySearchMode::Hybrid => {
                    let mut sql = r#"
                        SELECT me.entry_id, me.created_at, me.updated_at, me.kind, me.scope, 
                               me.tags, me.source, me.importance, me.nonce_b64, me.ciphertext_b64, 
                               me.plaintext_sha256, vec_distance_cosine(em.embedding, vec_f32(?)) as semantic_score
                        FROM memory_entries me
                        JOIN memory_embeddings em ON me.entry_id = em.entry_id
                    "#.to_string();

                    let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> =
                        vec![Box::new(query_embedding_bytes.clone())];

                    if let Some(ref s) = scope {
                        sql.push_str(" WHERE me.scope = ?");
                        params_vec.push(Box::new(s.clone()));
                    }

                    sql.push_str(" ORDER BY semantic_score ASC LIMIT ?");
                    params_vec.push(Box::new((limit * 3) as i32));

                    let params: Vec<&dyn rusqlite::ToSql> =
                        params_vec.iter().map(|p| p.as_ref()).collect();

                    let mut stmt = db.prepare(&sql)?;
                    let rows = stmt
                        .query_map(params.as_slice(), |row| {
                            let tags_json: String = row.get(5)?;
                            let tags: Vec<String> =
                                serde_json::from_str(&tags_json).unwrap_or_default();
                            let semantic_score: f32 = row.get(11)?;

                            Ok((
                                EncryptedMemoryEntry {
                                    entry_id: row.get(0)?,
                                    created_at:
                                        DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                                            .map(|dt| dt.with_timezone(&Utc))
                                            .unwrap_or_else(|_| Utc::now()),
                                    updated_at:
                                        DateTime::parse_from_rfc3339(&row.get::<_, String>(2)?)
                                            .map(|dt| dt.with_timezone(&Utc))
                                            .unwrap_or_else(|_| Utc::now()),
                                    kind: row.get(3)?,
                                    scope: row.get(4)?,
                                    tags,
                                    source: row.get(6)?,
                                    importance: row.get::<_, i32>(7)? as u8,
                                    nonce_b64: row.get(8)?,
                                    ciphertext_b64: row.get(9)?,
                                    plaintext_sha256: row.get(10)?,
                                },
                                semantic_score,
                            ))
                        })?
                        .collect::<Result<Vec<_>, _>>()?;

                    let mut scored = Vec::new();
                    for (enc, semantic_score) in rows {
                        if let Ok(entry) = decrypt_entry(&enc) {
                            let lexical = lexical_score(&query_lc, &entry);
                            let semantic_sim = 1.0 - semantic_score as f64;
                            let hybrid_score = (lexical * 0.45) + (semantic_sim * 0.55);
                            if hybrid_score > 0.0 {
                                scored.push((enc, hybrid_score as f32));
                            }
                        }
                    }

                    Ok(scored)
                }
            }
        })
        .await??;

        let mut results: Vec<MemorySearchResult> = results
            .into_iter()
            .filter_map(|(enc, score)| {
                decrypt_entry(&enc).ok().map(|entry| MemorySearchResult {
                    entry,
                    score: score as f64,
                })
            })
            .collect();

        if mode != MemorySearchMode::Semantic {
            results.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }

        results.truncate(limit);
        Ok(results)
    }

    pub async fn delete_entry(&self, entry_id: &str) -> Result<bool> {
        let entry_id = normalize_non_empty(entry_id).context("entry_id is required")?;

        let db_path = self.db_path.clone();

        let deleted = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;

            let deleted = tx.execute(
                "DELETE FROM memory_entries WHERE entry_id = ?",
                params![entry_id],
            )?;

            tx.execute(
                "DELETE FROM memory_embeddings WHERE entry_id = ?",
                params![entry_id],
            )?;

            tx.commit()?;
            Ok::<_, anyhow::Error>(deleted > 0)
        })
        .await??;

        Ok(deleted)
    }

    pub async fn stats(&self) -> MemoryStats {
        let db_path = self.db_path.clone();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let total_entries: usize = db
                .query_row("SELECT COUNT(*) FROM memory_entries", [], |row| {
                    row.get::<_, i32>(0)
                })
                .unwrap_or(0) as usize;

            let mut stats = MemoryStats {
                total_entries,
                ..MemoryStats::default()
            };

            let mut stmt = db
                .prepare("SELECT kind, scope, updated_at FROM memory_entries")
                .ok();

            if let Some(ref mut stmt) = stmt {
                let entries = stmt
                    .query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    })
                    .ok();

                if let Some(entries) = entries {
                    for entry in entries.flatten() {
                        *stats.by_kind.entry(entry.0).or_insert(0) += 1;
                        *stats.by_scope.entry(entry.1).or_insert(0) += 1;
                        if let Ok(dt) = DateTime::parse_from_rfc3339(&entry.2) {
                            let dt = dt.with_timezone(&Utc);
                            stats.last_updated_at = match stats.last_updated_at {
                                Some(ts) if ts > dt => Some(ts),
                                _ => Some(dt),
                            };
                        }
                    }
                }
            }

            Ok::<_, anyhow::Error>(stats)
        })
        .await
        .unwrap_or_else(|_| Ok(MemoryStats::default()))
        .unwrap_or_default()
    }

    pub async fn mcp_context(&self, query: &str, limit: usize) -> Result<serde_json::Value> {
        let results = self
            .search_entries_with_mode(query, limit, None, MemorySearchMode::Hybrid)
            .await?;
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
            "search_mode": "hybrid",
            "embedding_model": "sqlite-vec (768 dims)",
            "resources": resources,
            "count": results.len(),
        }))
    }

    pub async fn correlation_graph(&self, limit: usize) -> Result<serde_json::Value> {
        let limit = limit.clamp(1, 1000);
        let entries = self.list_entries(limit, None, None).await?;

        let mut node_set = BTreeMap::<String, serde_json::Value>::new();
        let mut edge_counts = BTreeMap::<(String, String, String), usize>::new();

        for entry in entries {
            let source_node = format!("source:{}", entry.source);
            node_set.entry(source_node.clone()).or_insert_with(|| {
                serde_json::json!({
                    "id": source_node,
                    "type": "source",
                    "label": entry.source
                })
            });

            let kind_node = format!("kind:{}", entry.kind);
            node_set.entry(kind_node.clone()).or_insert_with(|| {
                serde_json::json!({
                    "id": kind_node,
                    "type": "kind",
                    "label": entry.kind
                })
            });
            *edge_counts
                .entry((source_node.clone(), kind_node, "source_kind".to_string()))
                .or_insert(0) += 1;

            let scope_node = format!("scope:{}", entry.scope);
            node_set.entry(scope_node.clone()).or_insert_with(|| {
                serde_json::json!({
                    "id": scope_node,
                    "type": "scope",
                    "label": entry.scope
                })
            });
            *edge_counts
                .entry((source_node.clone(), scope_node, "source_scope".to_string()))
                .or_insert(0) += 1;

            for tag in entry.tags {
                let tag_node = format!("tag:{}", tag);
                node_set.entry(tag_node.clone()).or_insert_with(|| {
                    serde_json::json!({
                        "id": tag_node,
                        "type": "tag",
                        "label": tag
                    })
                });
                *edge_counts
                    .entry((source_node.clone(), tag_node, "source_tag".to_string()))
                    .or_insert(0) += 1;
            }
        }

        let nodes = node_set.into_values().collect::<Vec<_>>();
        let edges = edge_counts
            .into_iter()
            .map(|((from, to, relation), weight)| {
                serde_json::json!({
                    "from": from,
                    "to": to,
                    "relation": relation,
                    "weight": weight
                })
            })
            .collect::<Vec<_>>();

        Ok(serde_json::json!({
            "schema": "life-memory-graph/v1",
            "nodes": nodes,
            "edges": edges,
            "nodes_count": nodes.len(),
            "edges_count": edges.len(),
            "sampled_entries": limit,
        }))
    }

    async fn migrate_from_json(&self) -> Result<()> {
        let json_path = self.data_dir.join(STATE_FILE);
        if !json_path.exists() {
            return Ok(());
        }

        log::info!("Migrating memory entries from JSON to SQLite...");

        let content = tokio::fs::read_to_string(&json_path)
            .await
            .context("Failed to read legacy JSON state")?;
        let state: MemoryPlaneState =
            serde_json::from_str(&content).context("Failed to parse legacy JSON state")?;

        let db_path = self.db_path.clone();
        let count = state.entries.len();

        for entry in state.entries {
            let content =
                decrypt_to_string(&entry.nonce_b64, &entry.ciphertext_b64).unwrap_or_default();
            let (embedding, embedding_source) = self.generate_embedding(&content).await;

            let db_path_clone = db_path.clone();
            let entry_clone = entry.clone();
            let embedding_bytes: Vec<u8> = embedding.iter().flat_map(|f| f.to_le_bytes()).collect();

            tokio::task::spawn_blocking(move || {
                let db = Self::open_db(&db_path_clone)?;
                let tx = db.unchecked_transaction()?;

                tx.execute(
                    "INSERT OR IGNORE INTO memory_entries 
                     (entry_id, created_at, updated_at, kind, scope, tags, source, importance, 
                      nonce_b64, ciphertext_b64, plaintext_sha256, embedding_source)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    params![
                        entry_clone.entry_id,
                        entry_clone.created_at.to_rfc3339(),
                        entry_clone.updated_at.to_rfc3339(),
                        entry_clone.kind,
                        entry_clone.scope,
                        serde_json::to_string(&entry_clone.tags)?,
                        entry_clone.source,
                        entry_clone.importance as i32,
                        entry_clone.nonce_b64,
                        entry_clone.ciphertext_b64,
                        entry_clone.plaintext_sha256,
                        embedding_source,
                    ],
                )?;

                tx.execute(
                    "INSERT OR IGNORE INTO memory_embeddings (entry_id, embedding) VALUES (?1, vec_f32(?2))",
                    params![entry_clone.entry_id, embedding_bytes],
                )?;

                tx.commit()?;
                Ok::<_, anyhow::Error>(())
            }).await??;
        }

        let backup_path = json_path.with_extension("json.bak");
        tokio::fs::rename(&json_path, &backup_path).await?;

        log::info!("Migrated {} entries from JSON to SQLite", count);
        Ok(())
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

fn decrypt_entry(record: &EncryptedMemoryEntry) -> Result<MemoryEntry> {
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

fn decrypt_to_string(nonce_b64: &str, ciphertext_b64: &str) -> Result<String> {
    let cipher = cipher()?;
    let nonce_bytes = B64
        .decode(nonce_b64.as_bytes())
        .context("invalid nonce encoding")?;
    if nonce_bytes.len() != 12 {
        anyhow::bail!("invalid nonce length");
    }
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = B64
        .decode(ciphertext_b64.as_bytes())
        .context("invalid ciphertext encoding")?;
    let plaintext = cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|e| anyhow::anyhow!("failed to decrypt memory entry: {}", e))?;
    String::from_utf8(plaintext).context("memory plaintext is not utf-8")
}

fn hash_based_embedding_local(text: &str) -> Vec<f32> {
    if text.trim().is_empty() {
        return vec![0.0_f32; EMBEDDING_DIM];
    }
    let mut vector = vec![0.0_f32; EMBEDDING_DIM];
    let mut features = Vec::new();
    for word in text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|token| !token.trim().is_empty())
    {
        features.push(word.trim().to_lowercase());
    }

    let compact = text
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    for trigram in compact
        .as_bytes()
        .windows(3)
        .filter_map(|window| std::str::from_utf8(window).ok())
    {
        if trigram.trim().is_empty() {
            continue;
        }
        features.push(format!("tri:{}", trigram));
    }

    if features.is_empty() {
        return vec![0.0_f32; EMBEDDING_DIM];
    }

    for feature in features {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        feature.hash(&mut hasher);
        let h = hasher.finish();
        let idx = (h as usize) % EMBEDDING_DIM;
        let sign = if (h & 1) == 0 { 1.0_f32 } else { -1.0_f32 };
        vector[idx] += sign;
    }

    let norm = vector
        .iter()
        .map(|v| *v as f64 * *v as f64)
        .sum::<f64>()
        .sqrt();
    if norm <= f64::EPSILON {
        return vec![0.0_f32; EMBEDDING_DIM];
    }
    for v in &mut vector {
        *v /= norm as f32;
    }
    vector
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

fn semantic_embedding(text: &str) -> Vec<f32> {
    if text.trim().is_empty() {
        return Vec::new();
    }
    let mut vector = vec![0.0_f32; EMBEDDING_DIM];
    let mut features = Vec::new();
    for word in text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|token| !token.trim().is_empty())
    {
        features.push(word.trim().to_lowercase());
    }

    let compact = text
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    for trigram in compact
        .as_bytes()
        .windows(3)
        .filter_map(|window| std::str::from_utf8(window).ok())
    {
        if trigram.trim().is_empty() {
            continue;
        }
        features.push(format!("tri:{}", trigram));
    }

    if features.is_empty() {
        return vec![0.0_f32; EMBEDDING_DIM];
    }

    for feature in features {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        feature.hash(&mut hasher);
        let h = hasher.finish();
        let idx = (h as usize) % EMBEDDING_DIM;
        let sign = if (h & 1) == 0 { 1.0_f32 } else { -1.0_f32 };
        vector[idx] += sign;
    }

    let norm = vector
        .iter()
        .map(|v| *v as f64 * *v as f64)
        .sum::<f64>()
        .sqrt();
    if norm <= f64::EPSILON {
        return vec![0.0_f32; EMBEDDING_DIM];
    }
    for v in &mut vector {
        *v /= norm as f32;
    }
    vector
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
        mgr.initialize().await.unwrap();

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
        mgr.initialize().await.unwrap();

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
            .search_entries_with_mode(
                "runtime approval automation",
                5,
                Some("user"),
                MemorySearchMode::Hybrid,
            )
            .await
            .unwrap();
        assert!(!hits.is_empty());
        assert!(hits[0].entry.content.contains("run-until-done"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn sqlite_db_keeps_ciphertext_not_plaintext() {
        let dir = temp_dir("memory-plane-ciphertext");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();
        mgr.add_entry("note", "user", &[], None, 50, "plain text sentinel 123")
            .await
            .unwrap();

        let db_path = dir.join(DB_FILE);
        let db = Connection::open(&db_path).unwrap();
        let ciphertext: String = db
            .query_row(
                "SELECT ciphertext_b64 FROM memory_entries LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(!ciphertext.contains("plain text sentinel 123"));
        assert!(!ciphertext.is_empty());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn delete_entry_removes_record() {
        let dir = temp_dir("memory-plane-delete");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();
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

    #[tokio::test]
    async fn semantic_mode_matches_related_text() {
        let dir = temp_dir("memory-plane-semantic");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entry(
            "note",
            "user",
            &["automation".to_string()],
            None,
            60,
            "Approve runtime tasks automatically when trust mode is active.",
        )
        .await
        .unwrap();

        let hits = mgr
            .search_entries_with_mode(
                "automatic approval for runtime operations",
                3,
                Some("user"),
                MemorySearchMode::Semantic,
            )
            .await
            .unwrap();
        assert!(!hits.is_empty());
        assert!(hits[0].score > 0.15);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn correlation_graph_contains_source_tag_edges() {
        let dir = temp_dir("memory-plane-graph");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entry(
            "note",
            "workspace",
            &["release".to_string(), "qa".to_string()],
            Some("app://terminal"),
            70,
            "Run release QA checklist",
        )
        .await
        .unwrap();

        let graph = mgr.correlation_graph(20).await.unwrap();
        assert_eq!(graph["schema"].as_str(), Some("life-memory-graph/v1"));
        assert!(graph["nodes_count"].as_u64().unwrap_or(0) >= 3);
        assert!(graph["edges_count"].as_u64().unwrap_or(0) >= 2);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn stats_returns_correct_counts() {
        let dir = temp_dir("memory-plane-stats");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entry("note", "user", &[], None, 50, "entry 1")
            .await
            .unwrap();
        mgr.add_entry("task", "user", &[], None, 50, "entry 2")
            .await
            .unwrap();
        mgr.add_entry("note", "system", &[], None, 50, "entry 3")
            .await
            .unwrap();

        let stats = mgr.stats().await;
        assert_eq!(stats.total_entries, 3);
        assert_eq!(*stats.by_kind.get("note").unwrap_or(&0), 2);
        assert_eq!(*stats.by_kind.get("task").unwrap_or(&0), 1);
        assert_eq!(*stats.by_scope.get("user").unwrap_or(&0), 2);
        assert_eq!(*stats.by_scope.get("system").unwrap_or(&0), 1);

        std::fs::remove_dir_all(dir).ok();
    }
}
