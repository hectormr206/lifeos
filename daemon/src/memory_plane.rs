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
    embedding_source TEXT NOT NULL DEFAULT 'fallback',
    last_accessed TEXT,
    access_count INTEGER NOT NULL DEFAULT 0,
    mood TEXT
);

-- Vector search table (sqlite-vec)
CREATE VIRTUAL TABLE IF NOT EXISTS memory_embeddings USING vec0(
    entry_id TEXT PRIMARY KEY,
    embedding FLOAT[768]
);

-- Knowledge graph: directed triples (subject -[predicate]-> object)
CREATE TABLE IF NOT EXISTS knowledge_graph (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject TEXT NOT NULL,
    predicate TEXT NOT NULL,
    object TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(subject, predicate, object)
);

-- Procedural memory: reusable workflows/sequences
CREATE TABLE IF NOT EXISTS procedural_memory (
    proc_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    steps TEXT NOT NULL,
    trigger_pattern TEXT,
    times_used INTEGER NOT NULL DEFAULT 0,
    last_used TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_memory_kind ON memory_entries(kind);
CREATE INDEX IF NOT EXISTS idx_memory_scope ON memory_entries(scope);
CREATE INDEX IF NOT EXISTS idx_memory_created ON memory_entries(created_at);
CREATE INDEX IF NOT EXISTS idx_memory_kind_created ON memory_entries(kind, created_at);
CREATE INDEX IF NOT EXISTS idx_memory_importance ON memory_entries(importance);
CREATE INDEX IF NOT EXISTS idx_memory_last_accessed ON memory_entries(last_accessed);
CREATE INDEX IF NOT EXISTS idx_kg_subject ON knowledge_graph(subject);
CREATE INDEX IF NOT EXISTS idx_kg_object ON knowledge_graph(object);
CREATE INDEX IF NOT EXISTS idx_kg_predicate ON knowledge_graph(predicate);
CREATE INDEX IF NOT EXISTS idx_proc_name ON procedural_memory(name);

-- Cross-memory links (relates entries to each other)
CREATE TABLE IF NOT EXISTS memory_links (
    from_entry TEXT NOT NULL,
    to_entry TEXT NOT NULL,
    relation TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(from_entry, to_entry, relation)
);
CREATE INDEX IF NOT EXISTS idx_links_from ON memory_links(from_entry);
CREATE INDEX IF NOT EXISTS idx_links_to ON memory_links(to_entry);
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

/// Result of a [`MemoryPlaneManager::apply_decay`] pass.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct DecayReport {
    /// Number of entries whose importance was lowered by this pass.
    pub decayed: usize,
    /// Number of entries deleted because they fell below retention thresholds.
    pub deleted: usize,
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

        // Run forward-compatible migrations for columns added after initial release.
        Self::run_migrations(&db)?;

        Ok(Self {
            data_dir,
            db_path,
            ai_manager,
        })
    }

    /// Apply forward-compatible schema migrations for upgrades.
    ///
    /// Each migration uses `ALTER TABLE ... ADD COLUMN` wrapped in a check so it
    /// is idempotent — safe to run on every startup regardless of the current
    /// schema version.  SQLite does not support `ADD COLUMN IF NOT EXISTS`, so
    /// we probe `pragma_table_info` first.
    fn run_migrations(db: &Connection) -> Result<()> {
        // Helper: returns true if `table` already has a column called `col`.
        let has_column = |table: &str, col: &str| -> bool {
            db.prepare(&format!(
                "SELECT 1 FROM pragma_table_info('{}') WHERE name = ?1",
                table
            ))
            .and_then(|mut stmt| stmt.exists(rusqlite::params![col]))
            .unwrap_or(false)
        };

        // -- memory_entries migrations (added after v0.2) --
        if !has_column("memory_entries", "embedding_source") {
            db.execute_batch(
                "ALTER TABLE memory_entries ADD COLUMN embedding_source TEXT NOT NULL DEFAULT 'fallback';",
            )?;
        }
        if !has_column("memory_entries", "last_accessed") {
            db.execute_batch("ALTER TABLE memory_entries ADD COLUMN last_accessed TEXT;")?;
        }
        if !has_column("memory_entries", "access_count") {
            db.execute_batch(
                "ALTER TABLE memory_entries ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0;",
            )?;
        }
        if !has_column("memory_entries", "mood") {
            db.execute_batch("ALTER TABLE memory_entries ADD COLUMN mood TEXT;")?;
        }
        if !has_column("memory_entries", "permanent") {
            db.execute_batch(
                "ALTER TABLE memory_entries ADD COLUMN permanent INTEGER NOT NULL DEFAULT 0;",
            )?;
        }

        // -- knowledge_graph migrations --
        if !has_column("knowledge_graph", "confidence") {
            db.execute_batch(
                "ALTER TABLE knowledge_graph ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;",
            )?;
        }
        if !has_column("knowledge_graph", "source_entry_id") {
            db.execute_batch("ALTER TABLE knowledge_graph ADD COLUMN source_entry_id TEXT;")?;
        }

        Ok(())
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
        // Legacy migrations run in this order on every startup. Each one
        // is idempotent and cheap when there is nothing to migrate.
        //
        //   1. memory_plane_state.json  -> SQLite memory_entries
        //      (the very first storage backend, pre-SQLite)
        //   2. knowledge_graph/*.json   -> SQLite knowledge_graph triples
        //      (the JSON-backed graph removed in commit 2940422)
        //
        // Both migrations also auto-backup `memory.db` to a timestamped
        // file the first time they run, so a corrupted import never
        // costs the user their existing data.
        self.migrate_from_json().await?;
        self.migrate_legacy_knowledge_graph().await?;
        Ok(())
    }

    /// One-shot migration of the JSON-backed knowledge graph (removed in
    /// commit 2940422) into the SQLite triple store.
    ///
    /// Reads `<data_dir>/knowledge_graph/kg_entities.json` and
    /// `kg_relations.json` if they exist, converts each entity to a
    /// `(name, "is_a", entity_type)` triple, and each relation to a
    /// `(from_name, relation_type, to_name)` triple. Source files are
    /// renamed to `*.migrated-YYYYMMDD-HHMMSS` so subsequent startups
    /// no-op without losing the original data.
    ///
    /// Idempotent: if the source files do not exist, returns immediately.
    /// Auto-backs-up `memory.db` to
    /// `memory.db.pre-kg-migration-YYYYMMDD-HHMMSS.bak` before touching
    /// anything, but only the first time (subsequent migrations skip the
    /// backup if any `memory.db.pre-kg-migration-*.bak` is already present).
    async fn migrate_legacy_knowledge_graph(&self) -> Result<()> {
        let kg_dir = self.data_dir.join("knowledge_graph");
        let entities_path = kg_dir.join("kg_entities.json");
        let relations_path = kg_dir.join("kg_relations.json");

        if !entities_path.exists() && !relations_path.exists() {
            return Ok(()); // nothing to migrate
        }

        log::info!(
            "memory_plane: detected legacy knowledge_graph JSON files at {} — running one-time migration",
            kg_dir.display()
        );

        // -- Auto-backup memory.db before mutating anything. ---------------
        // We only back up if no prior `pre-kg-migration` backup exists, so
        // a partially-completed migration does not get its safety net
        // overwritten on the next startup.
        if self.db_path.exists() {
            let backup_already_present = std::fs::read_dir(&self.data_dir)
                .map(|rd| {
                    rd.flatten().any(|entry| {
                        entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with("memory.db.pre-kg-migration-")
                    })
                })
                .unwrap_or(false);
            if !backup_already_present {
                let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
                let backup = self
                    .data_dir
                    .join(format!("memory.db.pre-kg-migration-{}.bak", stamp));
                match tokio::fs::copy(&self.db_path, &backup).await {
                    Ok(bytes) => log::info!(
                        "memory_plane: pre-migration backup written to {} ({} bytes)",
                        backup.display(),
                        bytes
                    ),
                    Err(e) => log::warn!(
                        "memory_plane: failed to back up memory.db before KG migration: {} (continuing anyway)",
                        e
                    ),
                }
            }
        }

        // -- Parse the two JSON files. We do NOT depend on the deleted
        // KnowledgeGraph structs — generic serde_json::Value is fine and
        // future-proof against minor schema drift in the source files.
        let entities: Vec<serde_json::Value> = match tokio::fs::read_to_string(&entities_path).await
        {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        let relations: Vec<serde_json::Value> = match tokio::fs::read_to_string(&relations_path)
            .await
        {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Vec::new(),
        };

        // Build id -> name lookup so we can resolve `from_id` / `to_id`
        // in the relation file back to entity names.
        let mut id_to_name: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut entity_count = 0usize;
        for ent in &entities {
            let id = ent
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            let name = ent
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            // Entity type was an enum variant in the deleted module:
            // `"Person"`, `"Project"`, etc. We accept both an enum-like
            // string and an object with a `"type"` field for resilience.
            let etype = ent
                .get("entity_type")
                .and_then(|v| v.as_str())
                .map(|s| s.to_lowercase())
                .or_else(|| {
                    ent.get("entity_type")
                        .and_then(|v| v.get("type"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_lowercase())
                })
                .unwrap_or_else(|| "topic".to_string());
            if id.is_empty() || name.is_empty() {
                continue;
            }
            id_to_name.insert(id, name.clone());
            if let Err(e) = self.add_triple(&name, "is_a", &etype, 1.0, None).await {
                log::warn!(
                    "memory_plane: failed to migrate entity '{}': {} (skipping)",
                    name,
                    e
                );
            } else {
                entity_count += 1;
            }
        }

        let mut relation_count = 0usize;
        for rel in &relations {
            let from_id = rel.get("from_id").and_then(|v| v.as_str()).unwrap_or("");
            let to_id = rel.get("to_id").and_then(|v| v.as_str()).unwrap_or("");
            let rel_type = rel
                .get("relation_type")
                .and_then(|v| v.as_str())
                .unwrap_or("related_to");
            let confidence = rel
                .get("confidence")
                .and_then(|v| v.as_f64())
                .unwrap_or(1.0);
            let from_name = id_to_name.get(from_id);
            let to_name = id_to_name.get(to_id);
            if let (Some(f), Some(t)) = (from_name, to_name) {
                if let Err(e) = self.add_triple(f, rel_type, t, confidence, None).await {
                    log::warn!(
                        "memory_plane: failed to migrate relation '{}' --[{}]-> '{}': {} (skipping)",
                        f, rel_type, t, e
                    );
                } else {
                    relation_count += 1;
                }
            }
        }

        // -- Rename source files so we never re-run on next startup, but
        // keep them on disk as `*.migrated-*` evidence the user can
        // inspect or delete manually if they want.
        let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
        if entities_path.exists() {
            let migrated = kg_dir.join(format!("kg_entities.json.migrated-{}", stamp));
            if let Err(e) = tokio::fs::rename(&entities_path, &migrated).await {
                log::warn!(
                    "memory_plane: failed to rename {} to {}: {} (migration will re-run on next startup unless this is fixed)",
                    entities_path.display(),
                    migrated.display(),
                    e
                );
            }
        }
        if relations_path.exists() {
            let migrated = kg_dir.join(format!("kg_relations.json.migrated-{}", stamp));
            if let Err(e) = tokio::fs::rename(&relations_path, &migrated).await {
                log::warn!(
                    "memory_plane: failed to rename {} to {}: {}",
                    relations_path.display(),
                    migrated.display(),
                    e
                );
            }
        }

        log::info!(
            "memory_plane: legacy KG migration complete — {} entities + {} relations imported as SQLite triples",
            entity_count,
            relation_count
        );
        Ok(())
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

    /// Search memories within a UTC time range.
    ///
    /// Both `from_utc` and `to_utc` should be RFC3339 UTC strings.
    /// The caller is responsible for converting from local time to UTC
    /// (use `time_context::date_time_range_to_utc`).
    pub async fn search_by_time_range(
        &self,
        from_utc: &str,
        to_utc: &str,
        limit: usize,
    ) -> Result<Vec<MemoryEntry>> {
        let limit = limit.clamp(1, 500);
        let from = from_utc.to_string();
        let to = to_utc.to_string();
        let db_path = self.db_path.clone();

        let entries = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let mut stmt = db.prepare(
                "SELECT entry_id, created_at, updated_at, kind, scope, tags, source,
                        importance, nonce_b64, ciphertext_b64, plaintext_sha256
                 FROM memory_entries
                 WHERE created_at >= ?1 AND created_at <= ?2
                 ORDER BY created_at DESC
                 LIMIT ?3",
            )?;

            let entries = stmt
                .query_map(rusqlite::params![from, to, limit as i32], |row| {
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

        // Boost importance + last_accessed for any entries returned to a caller.
        // This is the "recall reinforces memory" half of the decay system.
        let hit_ids: Vec<String> = results.iter().map(|r| r.entry.entry_id.clone()).collect();
        if !hit_ids.is_empty() {
            if let Err(e) = self.boost_on_access(&hit_ids).await {
                log::warn!("memory_plane: boost_on_access failed: {}", e);
            }
        }

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

    /// Clean up vision memory entries with tiered retention.
    ///
    /// - Routine entries (importance < 70): deleted after `routine_max_hours`.
    /// - Key entries (importance >= 70): deleted after `key_max_days`.
    pub async fn cleanup_vision_entries(
        &self,
        routine_max_hours: u64,
        key_max_days: u64,
    ) -> Result<u64> {
        let db_path = self.db_path.clone();
        let now = Utc::now();
        let routine_cutoff = (now - chrono::Duration::hours(routine_max_hours as i64)).to_rfc3339();
        let key_cutoff = (now - chrono::Duration::days(key_max_days as i64)).to_rfc3339();

        let removed = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;

            // Collect entry_ids to delete from both tables.
            let mut stmt = tx.prepare(
                "SELECT entry_id FROM memory_entries
                 WHERE kind IN ('vision-snapshot', 'vision-context', 'screen-ocr')
                   AND (
                     (importance < 70 AND created_at < ?1)
                     OR (importance >= 70 AND created_at < ?2)
                   )",
            )?;
            let ids: Vec<String> = stmt
                .query_map(params![routine_cutoff, key_cutoff], |row| {
                    row.get::<_, String>(0)
                })?
                .filter_map(|r| r.ok())
                .collect();
            drop(stmt);

            let count = ids.len() as u64;
            for entry_id in &ids {
                tx.execute(
                    "DELETE FROM memory_entries WHERE entry_id = ?",
                    params![entry_id],
                )?;
                tx.execute(
                    "DELETE FROM memory_embeddings WHERE entry_id = ?",
                    params![entry_id],
                )?;
            }

            tx.commit()?;
            Ok::<_, anyhow::Error>(count)
        })
        .await??;

        Ok(removed)
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

    // -----------------------------------------------------------------------
    // Knowledge Graph (relational memory)
    // -----------------------------------------------------------------------

    /// Add a triple to the knowledge graph: subject -[predicate]-> object.
    pub async fn add_triple(
        &self,
        subject: &str,
        predicate: &str,
        object: &str,
        confidence: f64,
        source_entry_id: Option<&str>,
    ) -> Result<()> {
        let db_path = self.db_path.clone();
        let subject = subject.to_lowercase();
        let predicate = predicate.to_lowercase();
        let object = object.to_lowercase();
        let source = source_entry_id.map(|s| s.to_string());
        let now = Utc::now().to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO knowledge_graph (subject, predicate, object, confidence, source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
                 ON CONFLICT(subject, predicate, object) DO UPDATE SET
                    confidence = MAX(confidence, ?4),
                    updated_at = ?6",
                params![subject, predicate, object, confidence, source, now],
            )?;
            Ok(())
        })
        .await?
    }

    /// Query the knowledge graph for triples involving an entity.
    pub async fn query_graph(&self, entity: &str, limit: usize) -> Result<Vec<serde_json::Value>> {
        let db_path = self.db_path.clone();
        let entity = entity.to_lowercase();
        let limit = limit.clamp(1, 100) as i32;

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT subject, predicate, object, confidence, created_at
                 FROM knowledge_graph
                 WHERE subject = ?1 OR object = ?1
                 ORDER BY confidence DESC, updated_at DESC
                 LIMIT ?2",
            )?;
            let rows = stmt
                .query_map(params![entity, limit], |row| {
                    Ok(serde_json::json!({
                        "subject": row.get::<_, String>(0)?,
                        "predicate": row.get::<_, String>(1)?,
                        "object": row.get::<_, String>(2)?,
                        "confidence": row.get::<_, f64>(3)?,
                        "created_at": row.get::<_, String>(4)?,
                    }))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(rows)
        })
        .await?
    }

    /// Convenience wrapper: register an entity by name and type as a triple
    /// `(name, "is_a", type)`.
    ///
    /// Replaces the standalone `KnowledgeGraph::add_entity` API. Storing
    /// entities as `is_a` triples lets us reuse the same indexed table
    /// (`knowledge_graph` in this DB) instead of maintaining a parallel
    /// JSON-backed graph that did a full file rewrite on every insert.
    ///
    /// Entity names and types are normalised to lowercase to match the
    /// rest of the triple store.
    pub async fn add_entity_typed(&self, name: &str, entity_type: &str) -> Result<()> {
        let name = name.trim();
        let entity_type = entity_type.trim();
        if name.is_empty() || entity_type.is_empty() {
            return Ok(());
        }
        self.add_triple(name, "is_a", entity_type, 1.0, None).await
    }

    /// Export the entire `knowledge_graph` triple table as a JSON value.
    ///
    /// Used by `/api/v1/knowledge-graph/export`. Returns
    /// `{ "triples": [{ subject, predicate, object, confidence, created_at, updated_at }, ...] }`.
    /// Does not include encrypted memory entries — only the public triple
    /// store, which is plaintext metadata by design.
    pub async fn export_graph(&self) -> Result<serde_json::Value> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT subject, predicate, object, confidence, created_at, updated_at
                 FROM knowledge_graph
                 ORDER BY created_at ASC",
            )?;
            let rows: Vec<serde_json::Value> = stmt
                .query_map([], |row| {
                    Ok(serde_json::json!({
                        "subject": row.get::<_, String>(0)?,
                        "predicate": row.get::<_, String>(1)?,
                        "object": row.get::<_, String>(2)?,
                        "confidence": row.get::<_, f64>(3)?,
                        "created_at": row.get::<_, String>(4)?,
                        "updated_at": row.get::<_, String>(5)?,
                    }))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok::<_, anyhow::Error>(serde_json::json!({
                "triples": rows,
                "count": stmt.column_count(),
            }))
        })
        .await?
    }

    /// Import a JSON document produced by [`export_graph`].
    ///
    /// Expected shape: `{ "triples": [{ "subject": ..., "predicate": ..., "object": ..., "confidence": optional }, ...] }`.
    /// Returns the number of triples inserted (after dedup via the unique
    /// `(subject, predicate, object)` constraint).
    pub async fn import_graph(&self, value: &serde_json::Value) -> Result<usize> {
        let triples = value
            .get("triples")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut imported = 0usize;
        for t in triples {
            let subject = t.get("subject").and_then(|v| v.as_str()).unwrap_or("");
            let predicate = t.get("predicate").and_then(|v| v.as_str()).unwrap_or("");
            let object = t.get("object").and_then(|v| v.as_str()).unwrap_or("");
            let confidence = t.get("confidence").and_then(|v| v.as_f64()).unwrap_or(1.0);
            if subject.is_empty() || predicate.is_empty() || object.is_empty() {
                continue;
            }
            self.add_triple(subject, predicate, object, confidence, None)
                .await?;
            imported += 1;
        }
        Ok(imported)
    }

    // -----------------------------------------------------------------------
    // Procedural Memory (workflow memory)
    // -----------------------------------------------------------------------

    /// Save a procedure (reusable workflow).
    pub async fn save_procedure(
        &self,
        name: &str,
        description: &str,
        steps: &[String],
        trigger_pattern: Option<&str>,
    ) -> Result<String> {
        let db_path = self.db_path.clone();
        let proc_id = Uuid::new_v4().to_string();
        let name = name.to_string();
        let description = description.to_string();
        let steps_json = serde_json::to_string(steps)?;
        let trigger = trigger_pattern.map(|s| s.to_string());
        let now = Utc::now().to_rfc3339();
        let pid = proc_id.clone();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO procedural_memory (proc_id, name, description, steps, trigger_pattern, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
                 ON CONFLICT(name) DO UPDATE SET
                    description = ?3, steps = ?4, trigger_pattern = ?5, updated_at = ?6",
                params![pid, name, description, steps_json, trigger, now],
            )?;
            Ok(pid)
        })
        .await?
    }

    /// Find procedures matching a query (by name or trigger pattern).
    pub async fn find_procedures(&self, query: &str) -> Result<Vec<serde_json::Value>> {
        let db_path = self.db_path.clone();
        let query = format!("%{}%", query.to_lowercase());

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT proc_id, name, description, steps, trigger_pattern, times_used
                 FROM procedural_memory
                 WHERE LOWER(name) LIKE ?1 OR LOWER(description) LIKE ?1
                    OR (trigger_pattern IS NOT NULL AND LOWER(trigger_pattern) LIKE ?1)
                 ORDER BY times_used DESC
                 LIMIT 10",
            )?;
            let rows = stmt
                .query_map(params![query], |row| {
                    let steps_str: String = row.get(3)?;
                    let steps: Vec<String> = serde_json::from_str(&steps_str).unwrap_or_default();
                    Ok(serde_json::json!({
                        "proc_id": row.get::<_, String>(0)?,
                        "name": row.get::<_, String>(1)?,
                        "description": row.get::<_, String>(2)?,
                        "steps": steps,
                        "trigger_pattern": row.get::<_, Option<String>>(4)?,
                        "times_used": row.get::<_, i32>(5)?,
                    }))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(rows)
        })
        .await?
    }

    /// Mark a procedure as used (increments counter).
    pub async fn use_procedure(&self, name: &str) -> Result<()> {
        let db_path = self.db_path.clone();
        let name = name.to_string();
        let now = Utc::now().to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "UPDATE procedural_memory SET times_used = times_used + 1, last_used = ?2 WHERE name = ?1",
                params![name, now],
            )?;
            Ok(())
        })
        .await?
    }

    // -----------------------------------------------------------------------
    // Emotional Memory (mood tracking on entries)
    // -----------------------------------------------------------------------

    /// Update the mood metadata for a memory entry.
    pub async fn set_mood(&self, entry_id: &str, mood: &str) -> Result<()> {
        let db_path = self.db_path.clone();
        let entry_id = entry_id.to_string();
        let mood = mood.to_string();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "UPDATE memory_entries SET mood = ?2 WHERE entry_id = ?1",
                params![entry_id, mood],
            )?;
            Ok(())
        })
        .await?
    }

    /// Get recent mood entries to understand user emotional patterns.
    pub async fn mood_history(&self, limit: usize) -> Result<Vec<(String, String, String)>> {
        let db_path = self.db_path.clone();
        let limit = limit.clamp(1, 50) as i32;
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT entry_id, mood, created_at FROM memory_entries
                 WHERE mood IS NOT NULL AND mood != ''
                 ORDER BY created_at DESC LIMIT ?1",
            )?;
            let rows = stmt
                .query_map(params![limit], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(rows)
        })
        .await?
    }

    // -----------------------------------------------------------------------
    // Memory Consolidation & Forgetting
    // -----------------------------------------------------------------------

    /// Track access: update last_accessed and increment access_count.
    pub async fn track_access(&self, entry_id: &str) -> Result<()> {
        let db_path = self.db_path.clone();
        let entry_id = entry_id.to_string();
        let now = Utc::now().to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "UPDATE memory_entries SET last_accessed = ?2, access_count = access_count + 1 WHERE entry_id = ?1",
                params![entry_id, now],
            )?;
            Ok(())
        })
        .await?
    }

    /// Nocturnal consolidation: boost frequently accessed, degrade never-accessed.
    /// Returns (boosted_count, degraded_count, deleted_count).
    pub async fn consolidate(&self) -> Result<(usize, usize, usize)> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let now = Utc::now();
            let ninety_days_ago = (now - chrono::Duration::days(90)).to_rfc3339();
            let thirty_days_ago = (now - chrono::Duration::days(30)).to_rfc3339();

            // Boost: entries accessed 5+ times get importance +5 (cap at 100)
            let boosted = db.execute(
                "UPDATE memory_entries SET importance = MIN(importance + 5, 100)
                 WHERE access_count >= 5 AND importance < 100",
                [],
            )?;

            // Degrade: entries not accessed in 30 days with importance > 30 get -5
            let degraded = db.execute(
                "UPDATE memory_entries SET importance = MAX(importance - 5, 0)
                 WHERE (last_accessed IS NULL OR last_accessed < ?1)
                   AND importance > 30
                   AND access_count < 2",
                params![thirty_days_ago],
            )?;

            // Intelligent forgetting: soft delete (importance < 10, not accessed in 90 days)
            let deleted = db.execute(
                "DELETE FROM memory_entries
                 WHERE importance < 10
                   AND (last_accessed IS NULL OR last_accessed < ?1)
                   AND access_count < 1",
                params![ninety_days_ago],
            )?;

            // Also clean up orphaned embeddings
            db.execute(
                "DELETE FROM memory_embeddings WHERE entry_id NOT IN (SELECT entry_id FROM memory_entries)",
                [],
            )?;

            Ok((boosted, degraded, deleted))
        })
        .await?
    }

    // -----------------------------------------------------------------------
    // Cross-Memory Linking
    // -----------------------------------------------------------------------

    /// Link two memory entries with a relationship.
    pub async fn link_entries(&self, from_id: &str, to_id: &str, relation: &str) -> Result<()> {
        let db_path = self.db_path.clone();
        let from = from_id.to_string();
        let to = to_id.to_string();
        let rel = relation.to_string();
        let now = Utc::now().to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT OR IGNORE INTO memory_links (from_entry, to_entry, relation, created_at)
                 VALUES (?1, ?2, ?3, ?4)",
                params![from, to, rel, now],
            )?;
            Ok(())
        })
        .await?
    }

    /// Get all entries linked to a given entry.
    pub async fn get_linked(&self, entry_id: &str) -> Result<Vec<serde_json::Value>> {
        let db_path = self.db_path.clone();
        let eid = entry_id.to_string();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT from_entry, to_entry, relation, created_at
                 FROM memory_links
                 WHERE from_entry = ?1 OR to_entry = ?1
                 ORDER BY created_at DESC
                 LIMIT 20",
            )?;
            let rows = stmt
                .query_map(params![eid], |row| {
                    Ok(serde_json::json!({
                        "from": row.get::<_, String>(0)?,
                        "to": row.get::<_, String>(1)?,
                        "relation": row.get::<_, String>(2)?,
                        "created_at": row.get::<_, String>(3)?,
                    }))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(rows)
        })
        .await?
    }

    /// Cross-memory consolidation: find recent memories and auto-generate
    /// knowledge graph triples and causal links between them.
    /// Called during periodic consolidation.
    pub async fn cross_link_recent(
        &self,
        ai_manager: &Option<Arc<crate::ai::AiManager>>,
    ) -> Result<usize> {
        // Get recent memories (last 24h)
        let recent = self.list_entries(20, None, None).await?;
        if recent.len() < 2 {
            return Ok(0);
        }

        // Build a compact representation for LLM analysis
        let mut memory_list = String::new();
        for (i, entry) in recent.iter().enumerate() {
            memory_list.push_str(&format!(
                "{}. [{}] {} (id: {})\n",
                i + 1,
                entry.kind,
                &entry.content[..entry.content.len().min(100)],
                entry.entry_id
            ));
        }

        // Ask LLM to extract relationships
        let ai = match ai_manager {
            Some(a) => a,
            None => return Ok(0),
        };

        let prompt = format!(
            "Analiza estas memorias recientes y extrae SOLO relaciones claras.\n\
             Para cada relacion responde en formato: SUBJECT|PREDICATE|OBJECT\n\
             Ejemplo: hector|trabaja_en|lifeos\n\
             Solo responde con las lineas de relaciones, nada mas. Si no hay relaciones claras, responde NONE.\n\n\
             Memorias:\n{}",
            memory_list
        );

        let messages = vec![("user".to_string(), prompt)];
        let response_obj = match ai.chat(None, messages).await {
            Ok(r) => r,
            Err(_) => return Ok(0),
        };
        let response = response_obj.response;

        let mut count = 0;
        for line in response.lines() {
            let line = line.trim();
            if line == "NONE" || line.is_empty() {
                continue;
            }
            let parts: Vec<&str> = line.split('|').collect();
            if parts.len() == 3 {
                let subject = parts[0].trim();
                let predicate = parts[1].trim();
                let object = parts[2].trim();
                if !subject.is_empty() && !predicate.is_empty() && !object.is_empty() {
                    self.add_triple(subject, predicate, object, 0.8, None)
                        .await
                        .ok();
                    count += 1;
                }
            }
        }

        Ok(count)
    }

    /// Get memory health stats including consolidation metrics.
    pub async fn consolidation_stats(&self) -> Result<serde_json::Value> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let total: i32 =
                db.query_row("SELECT COUNT(*) FROM memory_entries", [], |r| r.get(0))?;
            let high_importance: i32 = db.query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE importance >= 70",
                [],
                |r| r.get(0),
            )?;
            let low_importance: i32 = db.query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE importance < 30",
                [],
                |r| r.get(0),
            )?;
            let never_accessed: i32 = db.query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE access_count = 0",
                [],
                |r| r.get(0),
            )?;
            let graph_triples: i32 = db
                .query_row("SELECT COUNT(*) FROM knowledge_graph", [], |r| r.get(0))
                .unwrap_or(0);
            let procedures: i32 = db
                .query_row("SELECT COUNT(*) FROM procedural_memory", [], |r| r.get(0))
                .unwrap_or(0);
            let moods: i32 = db
                .query_row(
                    "SELECT COUNT(*) FROM memory_entries WHERE mood IS NOT NULL AND mood != ''",
                    [],
                    |r| r.get(0),
                )
                .unwrap_or(0);

            Ok(serde_json::json!({
                "total_memories": total,
                "high_importance": high_importance,
                "low_importance": low_importance,
                "never_accessed": never_accessed,
                "knowledge_graph_triples": graph_triples,
                "procedures": procedures,
                "entries_with_mood": moods,
            }))
        })
        .await?
    }

    /// Delete garbage entries: very short ciphertext (proxy for <10 char plaintext)
    /// and entries tagged/sourced as "filler".
    pub async fn filter_garbage(&self) -> Result<usize> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;

            // ciphertext_b64 < 30 chars is a proxy for plaintext < 10 chars
            let deleted_short = tx.execute(
                "DELETE FROM memory_entries WHERE length(ciphertext_b64) < 30",
                [],
            )?;

            let deleted_filler = tx.execute(
                "DELETE FROM memory_entries WHERE tags = '\"filler\"' OR tags = '[\"filler\"]' OR source = 'filler'",
                [],
            )?;

            // Clean orphaned embeddings
            tx.execute_batch(
                "DELETE FROM memory_embeddings WHERE entry_id NOT IN (SELECT entry_id FROM memory_entries);",
            )?;

            tx.commit()?;
            Ok(deleted_short + deleted_filler)
        })
        .await?
    }

    /// Apply Ebbinghaus-inspired decay + connection bonus to memory entries.
    ///
    /// This is the canonical decay function and runs daily from the
    /// `lifeosd` housekeeping loop. It replaces both the older linear
    /// `-5/30d` curve and the standalone `apply_exponential_decay`
    /// helper that depended on SQLite's optional `power()` extension.
    ///
    /// # Curve
    ///
    /// For each non-permanent entry with `importance < 70`:
    ///
    /// 1. **Frequently-recalled (access_count >= 2):** the curve is
    ///    flat. Recall is its own reinforcement so we do not apply the
    ///    decay term — these entries are only candidates for the
    ///    connection bonus below.
    /// 2. **Otherwise:** `decayed = importance * 0.85^(days_since/30)`.
    ///    Half-life ≈ 128 days. Faster than linear in the 1-6 month
    ///    window (where most noise lives) and gentler in the long
    ///    tail (a 2-year-old fact still has a faint signal instead of
    ///    being clamped to 0).
    /// 3. **Connection bonus:** `bonus = min(links * 2, 20)` where
    ///    `links` is the count of incoming + outgoing edges in the
    ///    `memory_links` table. Densely-connected memories resist
    ///    forgetting — this is the structural counterpart to the
    ///    importance/recall reinforcement.
    /// 4. Final importance is clamped to `[0, 100]`.
    ///
    /// # Garbage collection
    ///
    /// After the decay/bonus pass, entries that satisfy any of the
    /// following are deleted (along with their embeddings and links):
    ///
    /// - `importance < 10` AND older than 90 days
    /// - `importance < 30` AND older than 180 days
    ///
    /// Permanent entries (`permanent = 1`) are skipped entirely at every
    /// stage. Entries with `importance >= 70` are kept indefinitely and
    /// not touched by the decay term, but they CAN still receive the
    /// connection bonus.
    ///
    /// # Performance
    ///
    /// All math runs in Rust over a single `SELECT` to avoid depending
    /// on SQLite's optional `power()` extension. Updates are batched
    /// inside one transaction. Cost is O(N) over non-permanent entries,
    /// fine for the daily cadence even at hundreds of thousands of
    /// rows.
    pub async fn apply_decay(&self) -> Result<DecayReport> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;
            let now_utc = chrono::Utc::now();

            // -- Phase 1: collect all candidate rows in one SELECT.
            //
            // We pull the link count via a correlated subquery so the
            // result already carries everything needed to compute the
            // new importance in Rust. The query also includes
            // importance >= 70 entries because they CAN still receive
            // the connection bonus (just not the decay term).
            let updates: Vec<(String, i32)> = {
                let mut stmt = tx.prepare(
                    "SELECT
                        e.entry_id,
                        e.importance,
                        COALESCE(e.last_accessed, e.updated_at) AS ts,
                        e.access_count,
                        (
                            SELECT COUNT(*) FROM memory_links l
                            WHERE l.from_entry = e.entry_id
                               OR l.to_entry = e.entry_id
                        ) AS link_count
                     FROM memory_entries e
                     WHERE (e.permanent IS NULL OR e.permanent = 0)",
                )?;

                let rows = stmt.query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i32>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i32>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                })?;

                let mut out: Vec<(String, i32)> = Vec::new();
                for row in rows {
                    let (entry_id, importance, ts, access_count, link_count) = row?;

                    // Parse timestamp; skip on parse error to stay safe.
                    let parsed = match chrono::DateTime::parse_from_rfc3339(&ts) {
                        Ok(t) => t.with_timezone(&chrono::Utc),
                        Err(_) => continue,
                    };
                    let days_since = (now_utc - parsed).num_days().max(0) as f64;

                    // Decay term: skipped for the >= 70 floor and for
                    // frequently-recalled entries.
                    let decayed: f64 = if importance >= 70 || access_count >= 2 {
                        importance as f64
                    } else {
                        let factor = 0.85_f64.powf(days_since / 30.0);
                        (importance as f64 * factor).round()
                    };

                    // Connection bonus: 2 importance per link, capped at 20.
                    // `link_count.min(10) * 2` is the same as
                    // `min(link_count * 2, 20)` but avoids overflow if
                    // some weird ingest path produced a huge link count.
                    let bonus = (link_count.min(10) as f64) * 2.0;

                    let new_importance =
                        (decayed + bonus).clamp(0.0, 100.0).round() as i32;

                    if new_importance != importance {
                        out.push((entry_id, new_importance));
                    }
                }
                out
            };

            let decayed = updates.len();
            for (id, new_imp) in &updates {
                tx.execute(
                    "UPDATE memory_entries SET importance = ?1 WHERE entry_id = ?2",
                    params![new_imp, id],
                )?;
            }

            // -- Phase 2: garbage-collect low-importance + old entries.
            let cutoff_90 = (now_utc - chrono::Duration::days(90)).to_rfc3339();
            let cutoff_180 = (now_utc - chrono::Duration::days(180)).to_rfc3339();

            // Collect ids first so we can also clean memory_embeddings.
            let mut to_delete: Vec<String> = Vec::new();
            {
                let mut stmt = tx.prepare(
                    "SELECT entry_id FROM memory_entries
                     WHERE (permanent IS NULL OR permanent = 0)
                       AND (
                           (importance < 10 AND COALESCE(last_accessed, updated_at) < ?1)
                           OR (importance < 30 AND COALESCE(last_accessed, updated_at) < ?2)
                       )",
                )?;
                let rows = stmt.query_map(params![cutoff_90, cutoff_180], |row| {
                    row.get::<_, String>(0)
                })?;
                for row in rows.flatten() {
                    to_delete.push(row);
                }
            }

            let deleted = to_delete.len();
            for entry_id in &to_delete {
                tx.execute(
                    "DELETE FROM memory_entries WHERE entry_id = ?1",
                    params![entry_id],
                )?;
                tx.execute(
                    "DELETE FROM memory_embeddings WHERE entry_id = ?1",
                    params![entry_id],
                )?;
            }

            tx.commit()?;
            Ok::<_, anyhow::Error>(DecayReport { decayed, deleted })
        })
        .await?
    }

    /// Boost importance for entries that were just accessed (recall/search hit).
    ///
    /// For each `entry_id`:
    /// - importance += 2 (capped at 100)
    /// - last_accessed = now
    /// - access_count += 1
    ///
    /// Permanent entries are still tracked (last_accessed/access_count) but
    /// their importance value is left untouched since it has no effect on
    /// retention.
    pub async fn boost_on_access(&self, entry_ids: &[String]) -> Result<()> {
        if entry_ids.is_empty() {
            return Ok(());
        }
        let ids: Vec<String> = entry_ids.to_vec();
        let db_path = self.db_path.clone();
        let now = Utc::now().to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;
            for id in &ids {
                tx.execute(
                    "UPDATE memory_entries
                     SET importance = MIN(100, importance + 2),
                         last_accessed = ?1,
                         access_count = access_count + 1
                     WHERE entry_id = ?2",
                    params![now, id],
                )?;
            }
            tx.commit()?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;
        Ok(())
    }

    /// Mark a memory entry as permanent (exempt from decay and garbage collection).
    pub async fn mark_permanent(&self, entry_id: &str) -> Result<()> {
        let entry_id = normalize_non_empty(entry_id).context("entry_id is required")?;
        let db_path = self.db_path.clone();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            // Ensure the permanent column exists (idempotent)
            let has_permanent: bool = db
                .prepare(
                    "SELECT 1 FROM pragma_table_info('memory_entries') WHERE name = 'permanent'",
                )
                .and_then(|mut stmt| stmt.exists([]))
                .unwrap_or(false);

            if !has_permanent {
                db.execute_batch(
                    "ALTER TABLE memory_entries ADD COLUMN permanent INTEGER DEFAULT 0;",
                )?;
            }

            db.execute(
                "UPDATE memory_entries SET permanent = 1 WHERE entry_id = ?1",
                params![entry_id],
            )?;

            Ok(())
        })
        .await?
    }

    /// Deduplicate entries with very similar embeddings (cosine similarity > threshold).
    ///
    /// Keeps the entry with higher importance; deletes the other.
    /// Returns the number of entries deleted.
    pub async fn dedup_similar(&self, similarity_threshold: f64) -> Result<usize> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let distance_threshold = 1.0 - similarity_threshold;

            // Find pairs that are too similar
            let mut stmt = db.prepare(
                "SELECT a.entry_id, b.entry_id, vec_distance_cosine(a.embedding, b.embedding) as dist
                 FROM memory_embeddings a, memory_embeddings b
                 WHERE a.entry_id < b.entry_id AND dist < ?1",
            )?;

            let pairs: Vec<(String, String)> = stmt
                .query_map(params![distance_threshold], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .filter_map(|r| r.ok())
                .collect();

            let mut deleted_ids: HashSet<String> = HashSet::new();
            let tx = db.unchecked_transaction()?;

            for (id_a, id_b) in &pairs {
                if deleted_ids.contains(id_a) || deleted_ids.contains(id_b) {
                    continue;
                }

                // Compare importance to decide which to keep
                let imp_a: i32 = tx
                    .query_row(
                        "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                        params![id_a],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                let imp_b: i32 = tx
                    .query_row(
                        "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                        params![id_b],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);

                let to_delete = if imp_a >= imp_b { id_b } else { id_a };

                tx.execute(
                    "DELETE FROM memory_entries WHERE entry_id = ?1",
                    params![to_delete],
                )?;
                tx.execute(
                    "DELETE FROM memory_embeddings WHERE entry_id = ?1",
                    params![to_delete],
                )?;

                deleted_ids.insert(to_delete.clone());
            }

            tx.commit()?;
            Ok(deleted_ids.len())
        })
        .await?
    }

    /// Return memory health statistics as a JSON object.
    pub async fn health_stats(&self) -> Result<serde_json::Value> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let total_entries: i32 =
                db.query_row("SELECT COUNT(*) FROM memory_entries", [], |r| r.get(0))?;

            let total_procedures: i32 = db
                .query_row("SELECT COUNT(*) FROM procedural_memory", [], |r| r.get(0))
                .unwrap_or(0);

            let total_kg_triples: i32 = db
                .query_row("SELECT COUNT(*) FROM knowledge_graph", [], |r| r.get(0))
                .unwrap_or(0);

            let avg_importance: f64 = db
                .query_row(
                    "SELECT COALESCE(AVG(importance), 0.0) FROM memory_entries",
                    [],
                    |r| r.get(0),
                )
                .unwrap_or(0.0);

            // Entries grouped by kind
            let mut entries_by_kind = serde_json::Map::new();
            {
                let mut stmt =
                    db.prepare("SELECT kind, COUNT(*) FROM memory_entries GROUP BY kind")?;
                let rows = stmt.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i32>(1)?))
                })?;
                for row in rows.flatten() {
                    entries_by_kind.insert(row.0, serde_json::Value::from(row.1));
                }
            }

            let oldest_entry: Option<String> = db
                .query_row("SELECT MIN(created_at) FROM memory_entries", [], |r| {
                    r.get(0)
                })
                .unwrap_or(None);

            let newest_entry: Option<String> = db
                .query_row("SELECT MAX(created_at) FROM memory_entries", [], |r| {
                    r.get(0)
                })
                .unwrap_or(None);

            // Permanent count (column may not exist)
            let permanent_count: i32 = db
                .prepare(
                    "SELECT 1 FROM pragma_table_info('memory_entries') WHERE name = 'permanent'",
                )
                .and_then(|mut stmt| stmt.exists([]))
                .unwrap_or(false)
                .then(|| {
                    db.query_row(
                        "SELECT COUNT(*) FROM memory_entries WHERE permanent = 1",
                        [],
                        |r| r.get::<_, i32>(0),
                    )
                    .unwrap_or(0)
                })
                .unwrap_or(0);

            Ok(serde_json::json!({
                "total_entries": total_entries,
                "total_procedures": total_procedures,
                "total_kg_triples": total_kg_triples,
                "avg_importance": avg_importance,
                "entries_by_kind": entries_by_kind,
                "oldest_entry": oldest_entry,
                "newest_entry": newest_entry,
                "permanent_count": permanent_count,
            }))
        })
        .await?
    }

    /// Export all memory data as JSON without decrypting content.
    pub async fn export_json(&self) -> Result<serde_json::Value> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            // Export memory_entries (metadata only, no decryption)
            let mut entries = Vec::new();
            {
                let mut stmt = db.prepare(
                    "SELECT entry_id, kind, scope, tags, importance, created_at, access_count
                     FROM memory_entries ORDER BY created_at DESC",
                )?;
                let rows = stmt.query_map([], |row| {
                    Ok(serde_json::json!({
                        "entry_id": row.get::<_, String>(0)?,
                        "kind": row.get::<_, String>(1)?,
                        "scope": row.get::<_, String>(2)?,
                        "tags": row.get::<_, String>(3)?,
                        "importance": row.get::<_, i32>(4)?,
                        "created_at": row.get::<_, String>(5)?,
                        "access_count": row.get::<_, i32>(6)?,
                    }))
                })?;
                for row in rows.flatten() {
                    entries.push(row);
                }
            }

            // Export knowledge_graph triples
            let mut triples = Vec::new();
            {
                let mut stmt = db.prepare(
                    "SELECT subject, predicate, object, confidence, source_entry_id, created_at
                     FROM knowledge_graph ORDER BY created_at DESC",
                )?;
                let rows = stmt.query_map([], |row| {
                    Ok(serde_json::json!({
                        "subject": row.get::<_, String>(0)?,
                        "predicate": row.get::<_, String>(1)?,
                        "object": row.get::<_, String>(2)?,
                        "confidence": row.get::<_, f64>(3)?,
                        "source_entry_id": row.get::<_, Option<String>>(4)?,
                        "created_at": row.get::<_, String>(5)?,
                    }))
                })?;
                for row in rows.flatten() {
                    triples.push(row);
                }
            }

            // Export procedural_memory
            let mut procedures = Vec::new();
            {
                let mut stmt = db.prepare(
                    "SELECT proc_id, name, description, steps, trigger_pattern, times_used, created_at
                     FROM procedural_memory ORDER BY created_at DESC",
                )?;
                let rows = stmt.query_map([], |row| {
                    Ok(serde_json::json!({
                        "proc_id": row.get::<_, String>(0)?,
                        "name": row.get::<_, String>(1)?,
                        "description": row.get::<_, String>(2)?,
                        "steps": row.get::<_, String>(3)?,
                        "trigger_pattern": row.get::<_, Option<String>>(4)?,
                        "times_used": row.get::<_, i32>(5)?,
                        "created_at": row.get::<_, String>(6)?,
                    }))
                })?;
                for row in rows.flatten() {
                    procedures.push(row);
                }
            }

            Ok(serde_json::json!({
                "memory_entries": entries,
                "knowledge_graph": triples,
                "procedural_memory": procedures,
            }))
        })
        .await?
    }

    /// Delete all user data (right to be forgotten).
    pub async fn delete_all_data(&self) -> Result<()> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            db.execute_batch(
                "DELETE FROM memory_entries;
                 DELETE FROM memory_embeddings;
                 DELETE FROM knowledge_graph;
                 DELETE FROM procedural_memory;
                 DELETE FROM memory_links;
                 VACUUM;",
            )?;

            Ok(())
        })
        .await?
    }

    /// Boost importance for well-connected memories (3+ knowledge graph relations).
    pub async fn apply_connection_bonus(&self) -> Result<usize> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            // Count relations per entry in knowledge_graph
            // For entries with 3+ relations, set minimum importance to 30
            let updated = db.execute(
                "UPDATE memory_entries SET importance = MAX(importance, 30)
                 WHERE entry_id IN (
                     SELECT source_entry_id FROM knowledge_graph
                     GROUP BY source_entry_id
                     HAVING COUNT(*) >= 3
                 )",
                [],
            )?;
            Ok(updated)
        })
        .await?
    }

    /// Archive old low-importance entries (older than 6 months, importance < 30).
    pub async fn archive_old_entries(&self) -> Result<usize> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            // Create archive table if not exists
            db.execute(
                "CREATE TABLE IF NOT EXISTS memory_archive (
                    entry_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    tags TEXT NOT NULL,
                    importance INTEGER NOT NULL,
                    archived_at TEXT NOT NULL
                )",
                [],
            )?;

            // Move entries older than 6 months with importance < 30
            let now_str = chrono::Utc::now().to_rfc3339();
            let cutoff = (chrono::Utc::now() - chrono::Duration::days(180)).to_rfc3339();

            // Check if the permanent column exists to avoid referencing it when absent
            let has_permanent: bool = db
                .prepare(
                    "SELECT 1 FROM pragma_table_info('memory_entries') WHERE name = 'permanent'",
                )
                .and_then(|mut stmt| stmt.exists([]))
                .unwrap_or(false);

            let permanent_filter = if has_permanent {
                "AND (permanent IS NULL OR permanent != 1)"
            } else {
                ""
            };

            let insert_sql = format!(
                "INSERT OR IGNORE INTO memory_archive
                     (entry_id, created_at, kind, scope, tags, importance, archived_at)
                 SELECT entry_id, created_at, kind, scope, tags, importance, ?1
                 FROM memory_entries
                 WHERE updated_at < ?2 AND importance < 30 {}",
                permanent_filter
            );

            let moved = db.execute(&insert_sql, rusqlite::params![now_str, cutoff])?;

            if moved > 0 {
                db.execute(
                    "DELETE FROM memory_entries WHERE entry_id IN \
                     (SELECT entry_id FROM memory_archive WHERE archived_at = ?1)",
                    rusqlite::params![now_str],
                )?;
            }

            Ok(moved)
        })
        .await?
    }

    /// Find tag clusters with 10+ entries older than 30 days (candidates for summarization).
    pub async fn get_cluster_candidates(&self) -> Result<Vec<(String, usize)>> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let cutoff = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();

            let mut stmt = db.prepare(
                "SELECT tags, COUNT(*) as cnt FROM memory_entries
                 WHERE updated_at < ?1
                 GROUP BY tags HAVING cnt >= 10
                 ORDER BY cnt DESC LIMIT 10",
            )?;

            let rows = stmt.query_map(rusqlite::params![cutoff], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, usize>(1)?))
            })?;

            let results: Vec<_> = rows.flatten().collect();
            Ok(results)
        })
        .await?
    }

    /// Result of a [`MemoryPlaneManager::summarize_clusters`] pass.
    ///
    /// `clusters_processed` is the number of tag-clusters that received a
    /// summary entry; `originals_archived` is the total number of source
    /// entries moved to `memory_archive`.
    pub async fn summarize_clusters_with_router(
        &self,
        router: &crate::llm_router::LlmRouter,
        max_clusters: usize,
        max_entries_per_cluster: usize,
    ) -> Result<ClusterSummaryReport> {
        use crate::llm_router::{ChatMessage, RouterRequest, TaskComplexity};

        let candidates = self.get_cluster_candidates().await?;
        let mut clusters_processed = 0usize;
        let mut originals_archived = 0usize;

        // Process at most `max_clusters` clusters per pass to keep the
        // nightly window predictable.
        for (tags_json, count) in candidates.into_iter().take(max_clusters) {
            // The grouping key from get_cluster_candidates is the raw
            // `tags` JSON column. Decode it to a Vec<String> so we can
            // pass real tags into list_entries / the new summary entry.
            let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();
            if tags.is_empty() {
                continue;
            }

            // Pull every entry that lives in this cluster (capped).
            // We use the first tag as the filter — list_entries only
            // accepts a single tag and that is enough to enclose the
            // group because the cluster is keyed by the FULL tags JSON,
            // so every member shares all tags including this one.
            let primary_tag = tags[0].clone();
            let entries = self
                .list_entries(max_entries_per_cluster, None, Some(&primary_tag))
                .await?;
            if entries.len() < 5 {
                // Below the floor — not enough to summarise meaningfully.
                continue;
            }

            // Build a compact prompt. We give the LLM the cluster's
            // tags + the chronological list of entries (truncated). The
            // model is asked to return ONE short paragraph in Spanish.
            let mut bullet_list = String::new();
            for e in &entries {
                let snippet: String = e.content.chars().take(220).collect();
                bullet_list.push_str(&format!(
                    "- [{}] {}\n",
                    e.created_at.format("%Y-%m-%d"),
                    snippet
                ));
            }

            let user_prompt = format!(
                "Tengo {} memorias antiguas con las etiquetas {:?}. \
                 Resúmelas en UN SOLO párrafo corto en español (máx 4 oraciones), \
                 conservando hechos clave, decisiones y nombres propios. \
                 No inventes nada. No uses markdown. Aquí están las memorias:\n\n{}",
                count, tags, bullet_list
            );

            let req = RouterRequest {
                messages: vec![ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(user_prompt),
                }],
                complexity: Some(TaskComplexity::Simple),
                sensitivity: None,
                preferred_provider: None,
                max_tokens: Some(400),
            };

            let summary_text = match router.chat(&req).await {
                Ok(resp) => resp.text.trim().to_string(),
                Err(e) => {
                    log::warn!(
                        "memory_plane: LLM summarization failed for cluster {:?}: {}",
                        tags,
                        e
                    );
                    continue;
                }
            };

            if summary_text.is_empty() {
                continue;
            }

            // Save the summary as a new memory entry. We mark it with
            // its own kind ("cluster_summary") and the original tags
            // so future searches still find it. Importance starts at 80
            // so the new entry survives decay long enough to actually
            // serve as the "narrative replacement" for the originals.
            let mut summary_tags = tags.clone();
            summary_tags.push("cluster_summary".to_string());
            let summary_content = format!(
                "Resumen de {} memorias del cluster {:?}:\n{}",
                count, tags, summary_text
            );
            let summary_entry = match self
                .add_entry(
                    "cluster_summary",
                    "user",
                    &summary_tags,
                    Some("memory_plane://summarize_clusters"),
                    80,
                    &summary_content,
                )
                .await
            {
                Ok(e) => e,
                Err(e) => {
                    log::warn!(
                        "memory_plane: failed to persist cluster summary for {:?}: {}",
                        tags,
                        e
                    );
                    continue;
                }
            };

            // Archive the originals so they no longer appear in normal
            // search but remain recoverable from `memory_archive`.
            // We do this in one transaction.
            let archived = self
                .archive_entries_by_id(
                    entries.iter().map(|e| e.entry_id.clone()).collect::<Vec<_>>(),
                )
                .await
                .unwrap_or(0);
            originals_archived += archived;
            clusters_processed += 1;

            log::info!(
                "memory_plane: summarised cluster {:?} ({} entries -> {}) and archived {} originals",
                tags,
                entries.len(),
                summary_entry.entry_id,
                archived
            );
        }

        Ok(ClusterSummaryReport {
            clusters_processed,
            originals_archived,
        })
    }

    /// Move a specific list of entry IDs into `memory_archive` and
    /// delete them from `memory_entries`.
    ///
    /// Used by `summarize_clusters_with_router` after the LLM produces
    /// the consolidated narrative entry. Skips permanent entries.
    pub async fn archive_entries_by_id(&self, ids: Vec<String>) -> Result<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            // Make sure the archive table exists (mirrors the layout used
            // by `archive_old_entries`).
            db.execute(
                "CREATE TABLE IF NOT EXISTS memory_archive (
                    entry_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    tags TEXT NOT NULL,
                    importance INTEGER NOT NULL,
                    archived_at TEXT NOT NULL
                )",
                [],
            )?;

            let has_permanent: bool = db
                .prepare(
                    "SELECT 1 FROM pragma_table_info('memory_entries') WHERE name = 'permanent'",
                )
                .and_then(|mut stmt| stmt.exists([]))
                .unwrap_or(false);

            let tx = db.unchecked_transaction()?;
            let now_str = chrono::Utc::now().to_rfc3339();
            let mut moved = 0usize;

            for id in &ids {
                // Skip permanent entries (defensive — caller should have
                // already filtered, but we double-check at the boundary).
                if has_permanent {
                    let is_permanent: bool = tx
                        .query_row(
                            "SELECT permanent FROM memory_entries WHERE entry_id = ?1",
                            params![id],
                            |r| r.get::<_, Option<i32>>(0).map(|v| v.unwrap_or(0) != 0),
                        )
                        .unwrap_or(false);
                    if is_permanent {
                        continue;
                    }
                }
                let inserted = tx.execute(
                    "INSERT OR IGNORE INTO memory_archive
                         (entry_id, created_at, kind, scope, tags, importance, archived_at)
                     SELECT entry_id, created_at, kind, scope, tags, importance, ?1
                     FROM memory_entries
                     WHERE entry_id = ?2",
                    params![now_str, id],
                )?;
                if inserted > 0 {
                    tx.execute(
                        "DELETE FROM memory_entries WHERE entry_id = ?1",
                        params![id],
                    )?;
                    tx.execute(
                        "DELETE FROM memory_embeddings WHERE entry_id = ?1",
                        params![id],
                    )?;
                    moved += 1;
                }
            }

            tx.commit()?;
            Ok::<_, anyhow::Error>(moved)
        })
        .await?
    }
}

/// Result of a [`MemoryPlaneManager::summarize_clusters_with_router`] pass.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct ClusterSummaryReport {
    pub clusters_processed: usize,
    pub originals_archived: usize,
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
    // Priority: env var > machine-derived key > hardcoded fallback
    let passphrase = std::env::var("LIFEOS_MEMORY_KEY")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(derive_machine_key);
    let key = Sha256::digest(passphrase.as_bytes());
    Aes256GcmSiv::new_from_slice(&key)
        .map_err(|e| anyhow::anyhow!("failed to initialize memory cipher: {}", e))
}

/// Derive a unique encryption key from the machine's identity.
/// Uses /etc/machine-id (unique per install, stable across reboots) + hostname
/// so each LifeOS installation has a different key without user configuration.
fn derive_machine_key() -> String {
    let machine_id = std::fs::read_to_string("/etc/machine-id")
        .unwrap_or_default()
        .trim()
        .to_string();
    let hostname = std::fs::read_to_string("/etc/hostname")
        .unwrap_or_default()
        .trim()
        .to_string();

    if machine_id.is_empty() {
        // Try to load or generate a persistent key file instead of using a hardcoded fallback
        let key_path = std::env::var("LIFEOS_DATA_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/lifeos"))
            .join("memory.key");

        // Try reading an existing key file
        if let Ok(existing) = std::fs::read_to_string(&key_path) {
            let trimmed = existing.trim().to_string();
            if !trimmed.is_empty() {
                return trimmed;
            }
        }

        // Generate a new random key, save it with restrictive permissions
        let mut rng_bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut rng_bytes);
        let generated_key: String = rng_bytes.iter().fold(String::new(), |mut acc, b| {
            use std::fmt::Write;
            let _ = write!(acc, "{:02x}", b);
            acc
        });

        if let Some(parent) = key_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        // Write with 0o600 permissions
        let wrote_ok = (|| -> std::io::Result<()> {
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&key_path)?;
            std::io::Write::write_all(&mut f, generated_key.as_bytes())?;
            Ok(())
        })();

        if wrote_ok.is_ok() {
            return generated_key;
        }

        // Only fall back to hardcoded key if both machine-id AND file generation fail
        log::warn!(
            "Could not read /etc/machine-id or create {}: falling back to default memory key",
            key_path.display()
        );
        return DEFAULT_MEMORY_KEY.to_string();
    }

    // Combine machine-id + hostname + salt for a unique-per-machine passphrase
    format!("lifeos:{}:{}:axi-memory-v1", machine_id, hostname)
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

/// Cheap pattern-based entity extraction.
///
/// Returns `Vec<(name, entity_type)>` where `entity_type` is one of the
/// short string tags used by [`MemoryPlaneManager::add_entity_typed`]:
/// `"date"`, `"person"`, `"file"`, `"topic"`. The result is intentionally
/// noisy-tolerant — recall matters more than precision because all
/// downstream consumers normalise + dedup via the unique constraint on
/// `knowledge_graph (subject, predicate, object)`.
///
/// Recognised patterns:
/// - ISO dates `YYYY-MM-DD` -> `date`
/// - Spanish day names (lunes..domingo, with or without accent) -> `date`
/// - `@username` mentions -> `person`
/// - Absolute paths (`/foo/bar`) and home paths (`~/foo`) -> `file`
/// - URLs (`http://`, `https://`) -> `topic`
///
/// Replaces the equivalent helper from the deleted `knowledge_graph`
/// module.
pub fn extract_entities_from_text(text: &str) -> Vec<(String, &'static str)> {
    use std::collections::HashSet;
    let mut found: Vec<(String, &'static str)> = Vec::new();
    let mut seen: HashSet<(String, &'static str)> = HashSet::new();

    // ISO dates YYYY-MM-DD via byte scan (avoid pulling in regex just for this).
    let bytes = text.as_bytes();
    let mut i = 0;
    while i + 10 <= bytes.len() {
        let slice = &bytes[i..i + 10];
        let is_date = slice[0].is_ascii_digit()
            && slice[1].is_ascii_digit()
            && slice[2].is_ascii_digit()
            && slice[3].is_ascii_digit()
            && slice[4] == b'-'
            && slice[5].is_ascii_digit()
            && slice[6].is_ascii_digit()
            && slice[7] == b'-'
            && slice[8].is_ascii_digit()
            && slice[9].is_ascii_digit();
        if is_date {
            let cap = std::str::from_utf8(slice).unwrap_or("").to_string();
            if seen.insert((cap.clone(), "date")) {
                found.push((cap, "date"));
            }
            i += 10;
        } else {
            i += 1;
        }
    }

    let days = [
        "lunes", "martes", "miercoles", "miércoles", "jueves", "viernes", "sabado", "sábado",
        "domingo",
    ];
    for word in text.split_whitespace() {
        let w = word
            .trim_matches(|c: char| c.is_ascii_punctuation())
            .to_lowercase();
        if days.contains(&w.as_str()) && seen.insert((w.clone(), "date")) {
            found.push((w, "date"));
        }
        if word.starts_with('@') && word.len() > 1 {
            let name = word
                .trim_start_matches('@')
                .trim_matches(|c: char| c.is_ascii_punctuation());
            if !name.is_empty() && seen.insert((name.to_string(), "person")) {
                found.push((name.to_string(), "person"));
            }
        }
        let clean = word.trim_matches(|c: char| c == ',' || c == ';' || c == ')' || c == '(');
        if (clean.starts_with('/') || clean.starts_with("~/"))
            && clean.len() > 2
            && !clean.starts_with("//")
            && seen.insert((clean.to_string(), "file"))
        {
            found.push((clean.to_string(), "file"));
        }
        if (clean.starts_with("https://") || clean.starts_with("http://"))
            && seen.insert((clean.to_string(), "topic"))
        {
            found.push((clean.to_string(), "topic"));
        }
    }

    found
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

    #[tokio::test]
    async fn filter_garbage_removes_filler_entries() {
        let dir = temp_dir("memory-plane-garbage");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Add a normal entry
        mgr.add_entry(
            "note",
            "user",
            &[],
            None,
            50,
            "This is a perfectly valid memory entry for testing.",
        )
        .await
        .unwrap();

        // Add a filler-tagged entry
        mgr.add_entry(
            "note",
            "user",
            &["filler".to_string()],
            None,
            10,
            "This filler entry should be deleted by garbage filter.",
        )
        .await
        .unwrap();

        // Add a filler-sourced entry
        mgr.add_entry(
            "note",
            "user",
            &[],
            Some("filler"),
            10,
            "Another filler entry sourced as filler content here.",
        )
        .await
        .unwrap();

        let entries_before = mgr.list_entries(100, None, None).await.unwrap();
        assert_eq!(entries_before.len(), 3);

        let deleted = mgr.filter_garbage().await.unwrap();
        assert!(
            deleted >= 2,
            "Expected at least 2 filler entries deleted, got {}",
            deleted
        );

        let entries_after = mgr.list_entries(100, None, None).await.unwrap();
        assert_eq!(entries_after.len(), 1);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn mark_permanent_sets_flag() {
        let dir = temp_dir("memory-plane-permanent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let entry = mgr
            .add_entry(
                "note",
                "user",
                &[],
                None,
                80,
                "This entry should be marked permanent.",
            )
            .await
            .unwrap();

        mgr.mark_permanent(&entry.entry_id).await.unwrap();

        // Verify via direct DB query
        let db_path = dir.join(DB_FILE);
        let db = Connection::open(&db_path).unwrap();
        let permanent: i32 = db
            .query_row(
                "SELECT permanent FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(permanent, 1);

        // Calling mark_permanent again should be idempotent
        mgr.mark_permanent(&entry.entry_id).await.unwrap();

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn health_stats_returns_expected_fields() {
        let dir = temp_dir("memory-plane-health");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entry(
            "note",
            "user",
            &[],
            None,
            60,
            "Health stats test entry one.",
        )
        .await
        .unwrap();
        mgr.add_entry(
            "task",
            "user",
            &[],
            None,
            80,
            "Health stats test entry two.",
        )
        .await
        .unwrap();

        let stats = mgr.health_stats().await.unwrap();

        assert_eq!(stats["total_entries"].as_i64().unwrap(), 2);
        assert_eq!(stats["total_procedures"].as_i64().unwrap(), 0);
        assert_eq!(stats["total_kg_triples"].as_i64().unwrap(), 0);
        assert!(stats["avg_importance"].as_f64().unwrap() > 0.0);
        assert!(stats["entries_by_kind"].is_object());
        assert_eq!(stats["entries_by_kind"]["note"].as_i64().unwrap(), 1);
        assert_eq!(stats["entries_by_kind"]["task"].as_i64().unwrap(), 1);
        assert!(stats["oldest_entry"].is_string());
        assert!(stats["newest_entry"].is_string());
        assert_eq!(stats["permanent_count"].as_i64().unwrap(), 0);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn apply_connection_bonus_boosts_connected_entries() {
        let dir = temp_dir("memory-plane-conn-bonus");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Add an entry with low importance
        let entry = mgr
            .add_entry("note", "user", &[], None, 10, "Connected entry.")
            .await
            .unwrap();

        // Manually insert 3+ knowledge_graph rows referencing this entry
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        for i in 0..3 {
            db.execute(
                "INSERT INTO knowledge_graph (subject, predicate, object, source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                rusqlite::params![
                    format!("subj_{}", i),
                    "related_to",
                    "some_object",
                    entry.entry_id,
                    chrono::Utc::now().to_rfc3339(),
                ],
            )
            .unwrap();
        }
        drop(db);

        let updated = mgr.apply_connection_bonus().await.unwrap();
        assert!(updated > 0, "Should have boosted at least one entry");

        // Verify importance was raised
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                rusqlite::params![entry.entry_id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            importance >= 30,
            "Importance should be at least 30, got {}",
            importance
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn archive_old_entries_moves_low_importance() {
        let dir = temp_dir("memory-plane-archive");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Add an entry with low importance
        let entry = mgr
            .add_entry("note", "user", &[], None, 5, "Old low-importance entry.")
            .await
            .unwrap();

        // Backdate the entry to 7 months ago so it qualifies for archival
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let old_date = (chrono::Utc::now() - chrono::Duration::days(220)).to_rfc3339();
        db.execute(
            "UPDATE memory_entries SET updated_at = ?1 WHERE entry_id = ?2",
            rusqlite::params![old_date, entry.entry_id],
        )
        .unwrap();
        drop(db);

        let moved = mgr.archive_old_entries().await.unwrap();
        assert_eq!(moved, 1, "Should have archived 1 entry");

        // Verify it was moved to archive and removed from main table
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let main_count: i32 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE entry_id = ?1",
                rusqlite::params![entry.entry_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(main_count, 0, "Entry should be removed from main table");

        let archive_count: i32 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_archive WHERE entry_id = ?1",
                rusqlite::params![entry.entry_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(archive_count, 1, "Entry should exist in archive table");

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- Sprint 2.1: memory decay tests ------------------------------------

    /// Helper: backdate the `last_accessed` (and `updated_at`) of an entry by
    /// `days` so it appears stale to the decay sweep.
    fn backdate(dir: &Path, entry_id: &str, days: i64) {
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let when = (chrono::Utc::now() - chrono::Duration::days(days)).to_rfc3339();
        db.execute(
            "UPDATE memory_entries SET last_accessed = ?1, updated_at = ?1 WHERE entry_id = ?2",
            params![when, entry_id],
        )
        .unwrap();
    }

    #[tokio::test]
    async fn test_apply_decay_skips_permanent() {
        let dir = temp_dir("memory-plane-decay-permanent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let entry = mgr
            .add_entry("note", "user", &[], None, 50, "Permanent decay-resistant.")
            .await
            .unwrap();
        mgr.mark_permanent(&entry.entry_id).await.unwrap();
        backdate(&dir, &entry.entry_id, 365);

        let report = mgr.apply_decay().await.unwrap();
        assert_eq!(report.deleted, 0, "Permanent entry must not be deleted");

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            importance, 50,
            "Permanent entry importance must be preserved"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_apply_decay_lowers_importance() {
        let dir = temp_dir("memory-plane-decay-lower");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // importance 60, age ~60 days => -10 importance => ~50
        let entry = mgr
            .add_entry("note", "user", &[], None, 60, "Stale moderate entry.")
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 60);

        let report = mgr.apply_decay().await.unwrap();
        assert!(
            report.decayed >= 1,
            "Should report at least one decayed entry"
        );

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            importance < 60,
            "Importance should have dropped from 60, got {}",
            importance
        );
        assert!(
            (40..=55).contains(&importance),
            "Importance should be ~50 after 60d decay, got {}",
            importance
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_apply_decay_deletes_low_importance_old() {
        let dir = temp_dir("memory-plane-decay-delete");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Low importance + > 90 days old => deleted by the <10/90d rule.
        let entry = mgr
            .add_entry("note", "user", &[], None, 5, "Old trivial entry.")
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 100);

        let report = mgr.apply_decay().await.unwrap();
        assert!(report.deleted >= 1, "Should delete at least one entry");

        let entries = mgr.list_entries(50, None, None).await.unwrap();
        assert!(
            entries.iter().all(|e| e.entry_id != entry.entry_id),
            "Stale low-importance entry should be deleted"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    /// Helper: forcibly set access_count on an entry to simulate
    /// frequently-recalled state without going through `boost_on_access`.
    fn set_access_count(dir: &Path, entry_id: &str, count: i32) {
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        db.execute(
            "UPDATE memory_entries SET access_count = ?1 WHERE entry_id = ?2",
            params![count, entry_id],
        )
        .unwrap();
    }

    /// Helper: insert a row into `memory_links` so the entry has N
    /// outgoing edges (with synthetic peer ids — they don't have to
    /// resolve to real entries for the link count subquery).
    fn add_synthetic_links(dir: &Path, entry_id: &str, n: usize) {
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let now = chrono::Utc::now().to_rfc3339();
        for i in 0..n {
            db.execute(
                "INSERT OR REPLACE INTO memory_links (from_entry, to_entry, relation, created_at)
                 VALUES (?1, ?2, 'related_to', ?3)",
                params![entry_id, format!("synthetic-peer-{}", i), now],
            )
            .unwrap();
        }
    }

    #[tokio::test]
    async fn test_apply_decay_skips_frequently_accessed() {
        let dir = temp_dir("memory-plane-decay-frequent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Importance 60, 60 days old → without the access guard this
        // would decay to ~43. With access_count >= 2 the curve is flat
        // and importance stays at 60.
        let entry = mgr
            .add_entry("note", "user", &[], None, 60, "Frequently recalled.")
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 60);
        set_access_count(&dir, &entry.entry_id, 5);

        let _report = mgr.apply_decay().await.unwrap();

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            importance, 60,
            "Frequently-accessed entry must skip the decay term, got {}",
            importance
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_apply_decay_connection_bonus_protects_linked_entries() {
        let dir = temp_dir("memory-plane-decay-bonus");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Importance 30, 60 days old, no recall.
        // Without the bonus: 30 * 0.85^2 = 21.7 → 22.
        // With 5 links: bonus = min(5*2, 20) = 10.
        // Final: 22 + 10 = 32 (which is HIGHER than the start because the
        // bonus exceeded the small decay).
        let entry = mgr
            .add_entry("note", "user", &[], None, 30, "Densely linked entry.")
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 60);
        add_synthetic_links(&dir, &entry.entry_id, 5);

        let _report = mgr.apply_decay().await.unwrap();

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();

        // The connection bonus must have raised importance back at or
        // above the decayed-without-bonus baseline (~22). 32 is the
        // exact expected value but we accept a small rounding window.
        assert!(
            (28..=36).contains(&importance),
            "Linked entry should be protected by bonus, got {}",
            importance
        );

        // Now verify that without links the same entry would have
        // dropped lower — confirms the bonus is the differentiator.
        let entry2 = mgr
            .add_entry("note", "user", &[], None, 30, "Lonely entry.")
            .await
            .unwrap();
        backdate(&dir, &entry2.entry_id, 60);
        let _ = mgr.apply_decay().await.unwrap();
        let lonely_importance: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![entry2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            lonely_importance < importance,
            "Lonely entry ({}) should decay further than linked one ({})",
            lonely_importance,
            importance
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_boost_on_access_increases_importance() {
        let dir = temp_dir("memory-plane-boost");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let entry = mgr
            .add_entry("note", "user", &[], None, 40, "Frequently recalled entry.")
            .await
            .unwrap();

        mgr.boost_on_access(&[entry.entry_id.clone()])
            .await
            .unwrap();
        mgr.boost_on_access(&[entry.entry_id.clone()])
            .await
            .unwrap();

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let (importance, access_count, last_accessed): (i32, i32, Option<String>) = db
            .query_row(
                "SELECT importance, access_count, last_accessed FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(importance, 44, "Two boosts of +2 should give 44");
        assert_eq!(access_count, 2, "access_count should be 2");
        assert!(last_accessed.is_some(), "last_accessed should be set");

        // Cap at 100 verification.
        let high = mgr
            .add_entry("note", "user", &[], None, 99, "Already near cap.")
            .await
            .unwrap();
        mgr.boost_on_access(&[high.entry_id.clone()]).await.unwrap();
        mgr.boost_on_access(&[high.entry_id.clone()]).await.unwrap();
        let capped: i32 = db
            .query_row(
                "SELECT importance FROM memory_entries WHERE entry_id = ?1",
                params![high.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(capped, 100, "importance must cap at 100");

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- Standalone KnowledgeGraph migration -------------------------------

    #[tokio::test]
    async fn test_add_entity_typed_creates_is_a_triple() {
        let dir = temp_dir("memory-plane-entity-typed");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entity_typed("Hector", "person").await.unwrap();
        mgr.add_entity_typed("LifeOS", "project").await.unwrap();
        // Same triple twice — must dedup via the unique constraint, not error.
        mgr.add_entity_typed("Hector", "person").await.unwrap();

        let triples = mgr.query_graph("hector", 10).await.unwrap();
        assert!(
            triples
                .iter()
                .any(|t| t["predicate"] == "is_a" && t["object"] == "person"),
            "expected (hector, is_a, person) triple, got {:?}",
            triples
        );

        let proj = mgr.query_graph("lifeos", 10).await.unwrap();
        assert!(proj
            .iter()
            .any(|t| t["predicate"] == "is_a" && t["object"] == "project"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_export_import_graph_roundtrip() {
        let dir = temp_dir("memory-plane-graph-roundtrip");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_entity_typed("Alice", "person").await.unwrap();
        mgr.add_triple("alice", "works_on", "lifeos", 0.9, None)
            .await
            .unwrap();

        let exported = mgr.export_graph().await.unwrap();
        let triples = exported["triples"].as_array().unwrap();
        assert!(triples.len() >= 2, "expected at least 2 triples in export");

        // Fresh manager — verify we can import the same JSON.
        let dir2 = temp_dir("memory-plane-graph-roundtrip-target");
        let mgr2 = MemoryPlaneManager::new(dir2.clone()).unwrap();
        mgr2.initialize().await.unwrap();
        let imported = mgr2.import_graph(&exported).await.unwrap();
        assert_eq!(imported, triples.len());

        let alice_triples = mgr2.query_graph("alice", 10).await.unwrap();
        assert_eq!(alice_triples.len(), 2);

        std::fs::remove_dir_all(dir).ok();
        std::fs::remove_dir_all(dir2).ok();
    }

    #[test]
    fn test_extract_entities_from_text_finds_dates_and_people() {
        let text =
            "El 2026-04-12 me reuno con @carlos en /home/user/proyectos sobre https://lifeos.dev";
        let entities = extract_entities_from_text(text);
        let kinds: Vec<&'static str> = entities.iter().map(|(_, k)| *k).collect();
        assert!(kinds.contains(&"date"));
        assert!(kinds.contains(&"person"));
        assert!(kinds.contains(&"file"));
        assert!(kinds.contains(&"topic"));
    }

    // ---- Cluster summarization helpers --------------------------------------

    #[tokio::test]
    async fn test_archive_entries_by_id_moves_and_deletes() {
        let dir = temp_dir("memory-plane-archive-by-id");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let e1 = mgr
            .add_entry(
                "note",
                "user",
                &["cluster_a".into()],
                None,
                40,
                "Original entry one",
            )
            .await
            .unwrap();
        let e2 = mgr
            .add_entry(
                "note",
                "user",
                &["cluster_a".into()],
                None,
                40,
                "Original entry two",
            )
            .await
            .unwrap();
        let e3 = mgr
            .add_entry(
                "note",
                "user",
                &["other".into()],
                None,
                40,
                "Unrelated entry",
            )
            .await
            .unwrap();

        let moved = mgr
            .archive_entries_by_id(vec![e1.entry_id.clone(), e2.entry_id.clone()])
            .await
            .unwrap();
        assert_eq!(moved, 2, "Both targeted entries should move");

        // Originals must be gone from memory_entries.
        let entries = mgr.list_entries(50, None, None).await.unwrap();
        let remaining_ids: Vec<&str> = entries.iter().map(|e| e.entry_id.as_str()).collect();
        assert!(!remaining_ids.contains(&e1.entry_id.as_str()));
        assert!(!remaining_ids.contains(&e2.entry_id.as_str()));
        // Unrelated entry must survive.
        assert!(remaining_ids.contains(&e3.entry_id.as_str()));

        // And they must live in memory_archive.
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let archive_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_archive WHERE entry_id IN (?1, ?2)",
                params![e1.entry_id, e2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(archive_count, 2);

        // Embeddings must be cleaned too.
        let embed_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_embeddings WHERE entry_id IN (?1, ?2)",
                params![e1.entry_id, e2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(embed_count, 0);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_archive_entries_by_id_skips_permanent() {
        let dir = temp_dir("memory-plane-archive-skip-permanent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let entry = mgr
            .add_entry(
                "note",
                "user",
                &["cluster".into()],
                None,
                50,
                "Permanent entry",
            )
            .await
            .unwrap();
        mgr.mark_permanent(&entry.entry_id).await.unwrap();

        let moved = mgr
            .archive_entries_by_id(vec![entry.entry_id.clone()])
            .await
            .unwrap();
        assert_eq!(moved, 0, "Permanent entry must NOT be archived");

        // The entry must still be present.
        let entries = mgr.list_entries(50, None, None).await.unwrap();
        assert!(entries.iter().any(|e| e.entry_id == entry.entry_id));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_legacy_kg_migration_imports_entities_and_relations() {
        let dir = temp_dir("memory-plane-legacy-kg-migration");
        std::fs::create_dir_all(&dir).unwrap();

        // Seed legacy JSON files in the location the deleted module
        // used: <data_dir>/knowledge_graph/{kg_entities,kg_relations}.json
        let kg_dir = dir.join("knowledge_graph");
        std::fs::create_dir_all(&kg_dir).unwrap();
        let entities = serde_json::json!([
            {
                "id": "ent-1",
                "name": "Hector",
                "entity_type": "Person",
                "properties": {},
                "created_at": "2026-01-01T00:00:00Z",
                "last_seen":  "2026-01-01T00:00:00Z",
                "relevance_score": 1.0
            },
            {
                "id": "ent-2",
                "name": "LifeOS",
                "entity_type": "Project",
                "properties": {},
                "created_at": "2026-01-01T00:00:00Z",
                "last_seen":  "2026-01-01T00:00:00Z",
                "relevance_score": 1.0
            }
        ]);
        let relations = serde_json::json!([
            {
                "from_id": "ent-1",
                "to_id": "ent-2",
                "relation_type": "works_on",
                "weight": 1.0,
                "context": "creator",
                "timestamp": "2026-01-01T00:00:00Z",
                "confidence": 0.95
            }
        ]);
        std::fs::write(
            kg_dir.join("kg_entities.json"),
            serde_json::to_string_pretty(&entities).unwrap(),
        )
        .unwrap();
        std::fs::write(
            kg_dir.join("kg_relations.json"),
            serde_json::to_string_pretty(&relations).unwrap(),
        )
        .unwrap();

        // Construct the manager and run initialize() — this triggers the
        // migration as part of normal startup, exactly like main.rs does.
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Both entities should now exist as `(name, "is_a", type)` triples.
        let hector_triples = mgr.query_graph("hector", 10).await.unwrap();
        assert!(
            hector_triples
                .iter()
                .any(|t| t["predicate"] == "is_a" && t["object"] == "person"),
            "Migration must create (hector, is_a, person), got {:?}",
            hector_triples
        );
        let lifeos_triples = mgr.query_graph("lifeos", 10).await.unwrap();
        assert!(lifeos_triples
            .iter()
            .any(|t| t["predicate"] == "is_a" && t["object"] == "project"));

        // The relation must be migrated and resolved through the
        // id->name lookup table built during migration.
        assert!(
            hector_triples
                .iter()
                .any(|t| t["predicate"] == "works_on" && t["object"] == "lifeos"),
            "Migration must create (hector, works_on, lifeos), got {:?}",
            hector_triples
        );

        // Source files must be renamed (not deleted) so we have evidence
        // and the second startup is a no-op.
        assert!(!kg_dir.join("kg_entities.json").exists());
        assert!(!kg_dir.join("kg_relations.json").exists());
        let migrated_files: Vec<String> = std::fs::read_dir(&kg_dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            migrated_files
                .iter()
                .any(|n| n.starts_with("kg_entities.json.migrated-")),
            "expected renamed entities file, got {:?}",
            migrated_files
        );
        assert!(migrated_files
            .iter()
            .any(|n| n.starts_with("kg_relations.json.migrated-")));

        // memory.db must have been auto-backed-up.
        let backup_files: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            backup_files
                .iter()
                .any(|n| n.starts_with("memory.db.pre-kg-migration-") && n.ends_with(".bak")),
            "expected auto-backup file, got {:?}",
            backup_files
        );

        // Second initialize() must be a no-op (idempotent). Triple counts
        // should not double.
        mgr.initialize().await.unwrap();
        let hector_after = mgr.query_graph("hector", 10).await.unwrap();
        assert_eq!(
            hector_triples.len(),
            hector_after.len(),
            "second initialize() must be a no-op"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_legacy_kg_migration_noop_when_no_files() {
        let dir = temp_dir("memory-plane-legacy-kg-migration-noop");
        std::fs::create_dir_all(&dir).unwrap();

        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        // Should succeed silently and create no backup file.
        mgr.initialize().await.unwrap();

        let backup_files: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            backup_files
                .iter()
                .all(|n| !n.starts_with("memory.db.pre-kg-migration-")),
            "no backup should be written when there is nothing to migrate, got {:?}",
            backup_files
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_get_cluster_candidates_finds_old_groups() {
        let dir = temp_dir("memory-plane-cluster-candidates");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Insert 12 entries with the same tags JSON, all > 30 days old.
        let mut ids = Vec::new();
        for i in 0..12 {
            let e = mgr
                .add_entry(
                    "note",
                    "user",
                    &["projectx".into()],
                    None,
                    20,
                    &format!("Entry number {}", i),
                )
                .await
                .unwrap();
            ids.push(e.entry_id);
        }
        for id in &ids {
            backdate(&dir, id, 45);
        }

        // And 3 fresh entries with different tags — these should NOT
        // create a cluster candidate (count < 10 AND too recent).
        for i in 0..3 {
            mgr.add_entry(
                "note",
                "user",
                &["recent".into()],
                None,
                20,
                &format!("Recent {}", i),
            )
            .await
            .unwrap();
        }

        let candidates = mgr.get_cluster_candidates().await.unwrap();
        assert!(
            !candidates.is_empty(),
            "Should find at least one cluster candidate"
        );
        let (_tags, count) = &candidates[0];
        assert!(*count >= 10, "Cluster size should meet the 10+ floor");

        std::fs::remove_dir_all(dir).ok();
    }
}
