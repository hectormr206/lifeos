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

-- ============================================================================
-- Fase BI.2 — Salud médica estructurada (Vida Plena)
-- ============================================================================
-- All five tables below live in the same memory.db file as memory_entries,
-- share the same encryption key for sensitive fields, share the same
-- backup, and link to memory_entries via `source_entry_id` so the narrative
-- and the structured fact stay coupled. Every row is auto-permanent at the
-- application level by virtue of the `health_*` kind being inserted into
-- memory_entries when the user records a health event.

-- Permanent facts: alergias, condiciones, tipo de sangre, contactos.
CREATE TABLE IF NOT EXISTS health_facts (
    fact_id TEXT PRIMARY KEY,
    fact_type TEXT NOT NULL,
    label TEXT NOT NULL,
    severity TEXT,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_health_facts_type ON health_facts(fact_type);

-- Medications as a HISTORY TABLE: every dose change is a new row.
CREATE TABLE IF NOT EXISTS health_medications (
    med_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dosage TEXT NOT NULL,
    frequency TEXT NOT NULL,
    condition TEXT,
    prescribed_by TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_health_meds_name ON health_medications(name);
CREATE INDEX IF NOT EXISTS idx_health_meds_active ON health_medications(ended_at);

-- Vital signs timeseries (presión, glucosa, peso, FC, etc.).
CREATE TABLE IF NOT EXISTS health_vitals (
    vital_id TEXT PRIMARY KEY,
    vital_type TEXT NOT NULL,
    value_numeric REAL,
    value_text TEXT,
    unit TEXT NOT NULL,
    measured_at TEXT NOT NULL,
    context TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_health_vitals_type_time
    ON health_vitals(vital_type, measured_at);

-- Resultados de laboratorio con rangos de referencia.
CREATE TABLE IF NOT EXISTS health_lab_results (
    lab_id TEXT PRIMARY KEY,
    test_name TEXT NOT NULL,
    value_numeric REAL NOT NULL,
    unit TEXT NOT NULL,
    reference_low REAL,
    reference_high REAL,
    measured_at TEXT NOT NULL,
    lab_name TEXT,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    attachment_id TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_health_labs_name_time
    ON health_lab_results(test_name, measured_at);

-- Adjuntos cifrados (recetas, radiografías, PDFs de análisis).
-- El archivo binario vive en ~/.local/share/lifeos/health_attachments/
-- cifrado con AES-GCM-SIV; este row solo guarda la metadata.
CREATE TABLE IF NOT EXISTS health_attachments (
    attachment_id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,
    file_type TEXT NOT NULL,
    description TEXT,
    related_event TEXT,
    sha256 TEXT NOT NULL,
    nonce_b64 TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_health_attachments_type
    ON health_attachments(file_type);

-- ============================================================================
-- Fase BI.7 — Crecimiento personal (Vida Plena)
-- ============================================================================
-- Reading log + habits + growth goals. No reinforced encryption — these
-- are not sensitive categories like mental health or sexual health. Notes
-- and reflections are still encrypted at rest using the same default key
-- as the rest of memory.db.
--
-- All inserts via the BI.7 API also create a `growth_*` kind entry in
-- memory_entries (see telegram_tools.rs / API), which means BI.1's
-- auto-permanent contract makes these rows survive decay forever even if
-- the user doesn't access them for years.

CREATE TABLE IF NOT EXISTS reading_log (
    book_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    author TEXT,
    isbn TEXT,
    status TEXT NOT NULL,            -- 'wishlist', 'reading', 'finished', 'abandoned'
    rating_1_5 INTEGER,
    started_at TEXT,
    finished_at TEXT,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reading_status ON reading_log(status);
CREATE INDEX IF NOT EXISTS idx_reading_author ON reading_log(author);

CREATE TABLE IF NOT EXISTS habits (
    habit_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    frequency TEXT NOT NULL,         -- 'daily', 'weekly:N', 'custom:MO,WE,FR'
    started_at TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_habits_active ON habits(active);

-- Per-day check-in log for habits. One row per (habit_id, date) — the
-- UNIQUE constraint enforces idempotency: marking the same habit twice
-- on the same day is a no-op via INSERT OR REPLACE.
CREATE TABLE IF NOT EXISTS habit_log (
    log_id TEXT PRIMARY KEY,
    habit_id TEXT NOT NULL,
    completed INTEGER NOT NULL,      -- 0 or 1
    logged_for_date TEXT NOT NULL,   -- YYYY-MM-DD
    notes TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(habit_id, logged_for_date)
);
CREATE INDEX IF NOT EXISTS idx_habit_log_habit_date
    ON habit_log(habit_id, logged_for_date);

CREATE TABLE IF NOT EXISTS growth_goals (
    goal_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    deadline TEXT,                   -- optional ISO-8601
    progress_pct INTEGER NOT NULL DEFAULT 0,  -- 0..100
    status TEXT NOT NULL,            -- 'active', 'paused', 'achieved', 'abandoned'
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_growth_goals_status ON growth_goals(status);

-- ============================================================================
-- Fase BI.5 — Ejercicio (Vida Plena)
-- ============================================================================
-- Hardware-aware exercise tracking. Three side-tables:
--   * exercise_inventory: lo que el usuario tiene a la mano (mancuernas,
--     ligas, banca, gym membership, etc.). Driving constraint para
--     proponer rutinas que el usuario PUEDA ejecutar.
--   * exercise_plans: rutinas guardadas (de Axi, de un entrenador, de
--     YouTube). Cada plan tiene una secuencia JSON de ejercicios.
--   * exercise_log: sesiones realizadas con tipo, duración, intensidad
--     percibida (RPE 1-10) y notas.
--
-- Las tres son auto-permanentes via la auto-permanencia BI.1 del kind
-- `exercise_*` en memory_entries. Notes y physical_limitations cifrados
-- con la clave default.

CREATE TABLE IF NOT EXISTS exercise_inventory (
    item_id TEXT PRIMARY KEY,
    item_name TEXT NOT NULL,         -- 'mancuerna ajustable 5-25kg'
    item_category TEXT NOT NULL,     -- 'free_weights', 'cardio', 'bands',
                                     -- 'machine', 'gym_access', 'space'
    quantity INTEGER NOT NULL DEFAULT 1,
    notes TEXT,                      -- libre: marca, peso máximo, estado
    active INTEGER NOT NULL DEFAULT 1,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_exercise_inv_category
    ON exercise_inventory(item_category);
CREATE INDEX IF NOT EXISTS idx_exercise_inv_active
    ON exercise_inventory(active);

CREATE TABLE IF NOT EXISTS exercise_plans (
    plan_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    goal TEXT,                       -- 'fuerza', 'cardio', 'flexibilidad',
                                     -- 'rehab', 'pérdida de peso', etc.
    sessions_per_week INTEGER,
    minutes_per_session INTEGER,
    exercises_json TEXT NOT NULL,    -- ver Rust ExercisePlanItem
    source TEXT,                     -- 'axi', 'usuario', 'entrenador:Pedro'
    active INTEGER NOT NULL DEFAULT 1,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_exercise_plans_active
    ON exercise_plans(active);

CREATE TABLE IF NOT EXISTS exercise_log (
    session_id TEXT PRIMARY KEY,
    plan_id TEXT,                    -- FK opcional a exercise_plans
    session_type TEXT NOT NULL,      -- 'strength', 'cardio', 'flexibility',
                                     -- 'sport', 'mixed'
    description TEXT NOT NULL,       -- libre: 'press de banca + remo + curl'
    duration_min INTEGER NOT NULL,
    rpe_1_10 INTEGER,                -- intensidad percibida 1-10
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    completed_at TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_exercise_log_completed
    ON exercise_log(completed_at);
CREATE INDEX IF NOT EXISTS idx_exercise_log_type
    ON exercise_log(session_type);

-- ============================================================================
-- Fase BI.3 sprint 1 — Nutricion (Vida Plena)
-- ============================================================================
-- Four side-tables for the food/nutrition layer:
--   * nutrition_preferences: alergias, intolerancias, dietas, gustos.
--     Auto-permanent via the nutrition_ kind contract.
--   * nutrition_log: cada comida/snack registrada por el usuario, con
--     descripcion libre + opcional foto/voz + macros estimados.
--   * nutrition_recipes: recetas guardadas con ingredientes + pasos
--     en JSON. Pueden venir de Axi, del usuario, o de un nutriologo.
--   * nutrition_plans: planes de alimentacion activos (de Axi o
--     subidos por el usuario).
--
-- Sprint 2 (BI.3.1) agregara nutrition_food_db precargada (USDA +
-- Open Food Facts MX + SMAE) y local_commerce_products / _stores
-- para las listas de compras filtradas por catalogo local. Esta
-- iteracion deja todo el storage layer + tools listos.

CREATE TABLE IF NOT EXISTS nutrition_preferences (
    pref_id TEXT PRIMARY KEY,
    pref_type TEXT NOT NULL,         -- 'allergy', 'intolerance', 'diet',
                                     -- 'like', 'dislike', 'goal'
    label TEXT NOT NULL,             -- 'mariscos', 'lactosa', 'mediterránea',
                                     -- 'aguacate', 'cilantro', 'bajar 5kg'
    severity TEXT,                   -- only relevant for allergy:
                                     -- 'mild', 'moderate', 'severe', 'life_threatening'
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_nutrition_pref_type
    ON nutrition_preferences(pref_type);
CREATE INDEX IF NOT EXISTS idx_nutrition_pref_active
    ON nutrition_preferences(active);

CREATE TABLE IF NOT EXISTS nutrition_log (
    log_id TEXT PRIMARY KEY,
    meal_type TEXT NOT NULL,         -- 'breakfast', 'lunch', 'dinner',
                                     -- 'snack', 'drink', 'craving'
    description TEXT NOT NULL,       -- texto libre o resultado de vision LLM
    photo_attachment_id TEXT,        -- FK opcional a health_attachments
    voice_attachment_id TEXT,        -- FK opcional a health_attachments
    macros_kcal REAL,                -- estimacion opcional
    macros_protein_g REAL,
    macros_carbs_g REAL,
    macros_fat_g REAL,
    consumed_at TEXT NOT NULL,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_nutrition_log_consumed
    ON nutrition_log(consumed_at);
CREATE INDEX IF NOT EXISTS idx_nutrition_log_meal_type
    ON nutrition_log(meal_type);

CREATE TABLE IF NOT EXISTS nutrition_recipes (
    recipe_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    ingredients_json TEXT NOT NULL,  -- ver Rust RecipeIngredient
    steps_json TEXT NOT NULL,        -- Vec<String>
    prep_time_min INTEGER,
    cook_time_min INTEGER,
    servings INTEGER,
    tags TEXT NOT NULL,              -- JSON: ["desayuno","alto_proteina"]
    source TEXT,                     -- 'axi', 'usuario', 'nutriologo:Juan'
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_nutrition_recipes_name
    ON nutrition_recipes(name);

CREATE TABLE IF NOT EXISTS nutrition_plans (
    plan_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    goal TEXT,                       -- 'control glucosa', 'bajar peso',
                                     -- 'ganar masa', 'mantener'
    duration_days INTEGER,
    daily_kcal_target REAL,
    daily_protein_g_target REAL,
    daily_carbs_g_target REAL,
    daily_fat_g_target REAL,
    source TEXT,                     -- 'axi', 'nutriologo:Maria'
    active INTEGER NOT NULL DEFAULT 1,
    started_at TEXT,
    notes_nonce_b64 TEXT,
    notes_ciphertext_b64 TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_nutrition_plans_active
    ON nutrition_plans(active);
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

/// BI.1: routing flag for the archived tier.
///
/// `ExcludeArchived` (default for live search): rows with `archived = 1`
/// are filtered out of the result. `OnlyArchived` (used by
/// `search_archived`): only rows with `archived = 1` come back. We use
/// an enum instead of a bare `bool` so callers can never confuse the
/// two paths at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ArchivedFilter {
    ExcludeArchived,
    OnlyArchived,
}

impl ArchivedFilter {
    /// Returns the SQL WHERE fragment for this filter, ready to AND
    /// with the rest of the conditions. Always wrapped in parentheses
    /// so it composes safely.
    fn sql_clause(self, table_alias: &str) -> String {
        let prefix = if table_alias.is_empty() {
            "".to_string()
        } else {
            format!("{}.", table_alias)
        };
        match self {
            Self::ExcludeArchived => {
                format!("({}archived IS NULL OR {}archived = 0)", prefix, prefix)
            }
            Self::OnlyArchived => format!("({}archived = 1)", prefix),
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
        // BI.1 (Fase Bienestar Integral): the `archived` column lets us
        // soft-archive entries instead of deleting them. The default search
        // path filters them out, but `search_archived` (and the
        // `recall_archived` Telegram tool) can still bring them back. This
        // is the "never lose anything" guarantee that unblocks every
        // wellness sub-fase.
        if !has_column("memory_entries", "archived") {
            db.execute_batch(
                "ALTER TABLE memory_entries ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;",
            )?;
            // Index speeds up the WHERE archived=0 filter that every
            // search/list call now adds. Cheap to create even on large
            // tables because the column is bool-ish.
            db.execute_batch(
                "CREATE INDEX IF NOT EXISTS idx_memory_archived ON memory_entries(archived);",
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
        let relations: Vec<serde_json::Value> =
            match tokio::fs::read_to_string(&relations_path).await {
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

        // BI.1: kinds in the wellness pillar are auto-permanent. Health
        // events, medications, vitals, lab results, mental journal,
        // relationship logs, etc. ALL skip decay/GC/dedup automatically.
        // The user does not have to remember to mark them — the kind
        // namespace is the contract.
        let auto_permanent = is_wellness_kind(&kind);

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
                  nonce_b64, ciphertext_b64, plaintext_sha256, embedding_source, permanent)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
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
                    if auto_permanent { 1 } else { 0 },
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
            // BI.1: archived rows are excluded from the default list
            // path. They live on disk but only appear via
            // `search_archived` / `recall_archived`.
            let mut conditions: Vec<&str> = vec!["(archived IS NULL OR archived = 0)"];
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(ref s) = scope {
                conditions.push("scope = ?");
                params_vec.push(Box::new(s.clone()));
            }

            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));

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

    /// BI.1: search the archived tier.
    ///
    /// Same hybrid (lexical + semantic) ranking as `search_entries`,
    /// but the archive filter is **inverted** — only entries flagged
    /// `archived = 1` are considered. Embeddings are preserved on
    /// archive so semantic recall over the archive works exactly the
    /// same as the live tier. Powers the `recall_archived` Telegram
    /// tool: *"tenía una idea genial pero ya no recuerdo qué era"*.
    pub async fn search_archived(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
    ) -> Result<Vec<MemorySearchResult>> {
        self.search_entries_inner(
            query,
            limit,
            scope,
            MemorySearchMode::Hybrid,
            ArchivedFilter::OnlyArchived,
        )
        .await
    }

    pub async fn search_entries_with_mode(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
        mode: MemorySearchMode,
    ) -> Result<Vec<MemorySearchResult>> {
        self.search_entries_inner(query, limit, scope, mode, ArchivedFilter::ExcludeArchived)
            .await
    }

    /// Inner implementation; the public wrappers fix the
    /// `archived_filter` so callers cannot accidentally surface
    /// archived entries from the live search path.
    async fn search_entries_inner(
        &self,
        query: &str,
        limit: usize,
        scope: Option<&str>,
        mode: MemorySearchMode,
        archived_filter: ArchivedFilter,
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
                    let mut where_parts: Vec<String> =
                        vec![archived_filter.sql_clause("me")];

                    if let Some(ref s) = scope {
                        where_parts.push("me.scope = ?".to_string());
                        params_vec.push(Box::new(s.clone()));
                    }

                    sql.push_str(" WHERE ");
                    sql.push_str(&where_parts.join(" AND "));
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
                    let archived_clause = archived_filter.sql_clause("");
                    let mut conditions: Vec<&str> =
                        vec!["ciphertext_b64 LIKE ?", archived_clause.as_str()];
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
                    let mut where_parts: Vec<String> =
                        vec![archived_filter.sql_clause("me")];

                    if let Some(ref s) = scope {
                        where_parts.push("me.scope = ?".to_string());
                        params_vec.push(Box::new(s.clone()));
                    }

                    sql.push_str(" WHERE ");
                    sql.push_str(&where_parts.join(" AND "));
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

                    let new_importance = (decayed + bonus).clamp(0.0, 100.0).round() as i32;

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

            // -- Phase 2: ARCHIVE low-importance old entries.
            //
            // BI.1 — "nunca perder nada" — what was previously a hard
            // DELETE is now a soft archive: we set `archived = 1` on
            // entries that hit the GC thresholds. They drop out of
            // normal search, free space in the search ranking for
            // fresh stuff, but stay recoverable via `search_archived`
            // and the `recall_archived` Telegram tool. Embeddings are
            // intentionally PRESERVED so semantic recall over the
            // archive still works ("tenía una idea genial pero no
            // recuerdo cuál era").
            //
            // The thresholds are unchanged (importance<10 + 90d, or
            // importance<30 + 180d). The only change is the verb:
            // archive instead of delete.
            //
            // Already-archived entries (archived = 1) are skipped so
            // we don't double-count them in the report.
            let cutoff_90 = (now_utc - chrono::Duration::days(90)).to_rfc3339();
            let cutoff_180 = (now_utc - chrono::Duration::days(180)).to_rfc3339();

            let archived = tx.execute(
                "UPDATE memory_entries
                 SET archived = 1
                 WHERE (permanent IS NULL OR permanent = 0)
                   AND (archived IS NULL OR archived = 0)
                   AND (
                       (importance < 10 AND COALESCE(last_accessed, updated_at) < ?1)
                       OR (importance < 30 AND COALESCE(last_accessed, updated_at) < ?2)
                   )",
                params![cutoff_90, cutoff_180],
            )?;

            tx.commit()?;
            // The `deleted` field now means "newly archived this pass".
            // We keep the field name for backward compatibility with
            // existing logging / dashboards that already read it.
            Ok::<_, anyhow::Error>(DecayReport {
                decayed,
                deleted: archived,
            })
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

                // BI.1: never fuse permanent entries OR wellness-pillar
                // entries. Two doses of the same medication are SEPARATE
                // events even if the text is identical — fusing them
                // would lose the second dose. We pull importance, kind,
                // and permanent in a single query per row to avoid
                // doing 6 queries per pair.
                let row_a: rusqlite::Result<(i32, String, i32)> = tx.query_row(
                    "SELECT importance, kind, COALESCE(permanent, 0) FROM memory_entries WHERE entry_id = ?1",
                    params![id_a],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                );
                let row_b: rusqlite::Result<(i32, String, i32)> = tx.query_row(
                    "SELECT importance, kind, COALESCE(permanent, 0) FROM memory_entries WHERE entry_id = ?1",
                    params![id_b],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                );

                let (imp_a, kind_a, perm_a) = match row_a {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                let (imp_b, kind_b, perm_b) = match row_b {
                    Ok(t) => t,
                    Err(_) => continue,
                };

                // Skip pair entirely if EITHER side is protected.
                if perm_a != 0
                    || perm_b != 0
                    || is_wellness_kind(&kind_a)
                    || is_wellness_kind(&kind_b)
                {
                    continue;
                }

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

            // BI.1: skip permanent + archived rows from the candidate
            // count. Permanent entries (which include all wellness
            // kinds) must NEVER be summarised away.
            let mut stmt = db.prepare(
                "SELECT tags, COUNT(*) as cnt FROM memory_entries
                 WHERE updated_at < ?1
                   AND (permanent IS NULL OR permanent = 0)
                   AND (archived IS NULL OR archived = 0)
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
            let raw_entries = self
                .list_entries(max_entries_per_cluster, None, Some(&primary_tag))
                .await?;

            // BI.1: defensively skip wellness-kind entries even if a
            // future bug ever lets one through `get_cluster_candidates`.
            // This is the second line of defence; the first is the
            // permanent filter on the candidate query above.
            let entries: Vec<MemoryEntry> = raw_entries
                .into_iter()
                .filter(|e| !is_wellness_kind(&e.kind))
                .collect();
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
                    entries
                        .iter()
                        .map(|e| e.entry_id.clone())
                        .collect::<Vec<_>>(),
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

    /// Soft-archive a specific list of entry IDs.
    ///
    /// Used by `summarize_clusters_with_router` after the LLM produces
    /// the consolidated narrative entry. Skips permanent entries
    /// AND wellness-pillar entries (defense in depth — the caller
    /// should already filter, but boundary checks are cheap).
    ///
    /// **BI.1 change:** previously this method moved entries to a
    /// separate `memory_archive` metadata-only table and deleted the
    /// originals (losing the encrypted content forever). Now it sets
    /// `archived = 1` on the row, preserving content + embeddings so
    /// `search_archived` can recover them later. The legacy
    /// `memory_archive` table is no longer written to but stays in the
    /// schema for any pre-existing data.
    pub async fn archive_entries_by_id(&self, ids: Vec<String>) -> Result<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let tx = db.unchecked_transaction()?;
            let mut moved = 0usize;

            for id in &ids {
                // Skip permanent + wellness entries defensively.
                let row: rusqlite::Result<(i32, String)> = tx.query_row(
                    "SELECT COALESCE(permanent, 0), kind
                     FROM memory_entries WHERE entry_id = ?1",
                    params![id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                );
                let (perm, kind) = match row {
                    Ok(t) => t,
                    Err(_) => continue, // entry does not exist anymore
                };
                if perm != 0 || is_wellness_kind(&kind) {
                    continue;
                }

                let n = tx.execute(
                    "UPDATE memory_entries
                     SET archived = 1
                     WHERE entry_id = ?1
                       AND (archived IS NULL OR archived = 0)",
                    params![id],
                )?;
                moved += n;
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

// ============================================================================
// Fase BI.2 — Salud médica estructurada (Vida Plena)
// ============================================================================

/// A persistent medical fact about the user.
///
/// Examples: alergia a la penicilina, diabetes tipo 2 desde 2024,
/// tipo de sangre O+, contacto de emergencia. Auto-permanent: never
/// decays, never archives, never dedups.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthFact {
    pub fact_id: String,
    /// Categoría: `allergy`, `condition`, `blood_type`, `emergency_contact`,
    /// `donor`, `insurance`, etc. (free text — convention only).
    pub fact_type: String,
    /// Etiqueta humana: "Penicilina", "Diabetes tipo 2", "O+",
    /// "Mamá: 555-1234".
    pub label: String,
    /// Severidad cuando aplica: `mild`, `moderate`, `severe`,
    /// `life_threatening`. None para hechos sin gravedad (tipo de
    /// sangre, contacto).
    pub severity: Option<String>,
    /// Notas adicionales — cifradas en disco. Vacío cuando no hay.
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One row in the medications history table.
///
/// **History semantics:** every dose change creates a NEW row. The
/// previous row gets `ended_at` set, never deleted. This means a
/// query for "qué tomas hoy" filters `WHERE ended_at IS NULL`, while
/// "todo el historial" simply selects all rows. Two rows for the
/// same medication name are normal and expected.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Medication {
    pub med_id: String,
    pub name: String,
    pub dosage: String,
    pub frequency: String,
    pub condition: Option<String>,
    pub prescribed_by: Option<String>,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One vital sign reading.
///
/// Most vitals fit in `value_numeric` (peso, glucosa, temperatura).
/// Blood pressure is the exception — it needs both systolic and
/// diastolic, so we either store it as two separate rows
/// (`blood_pressure_systolic`, `blood_pressure_diastolic`) sharing
/// the same `measured_at`, OR as a single row with `value_text =
/// "130/85"`. The convenience helpers in this module use the
/// two-row pattern because it makes timeseries queries cleaner.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Vital {
    pub vital_id: String,
    pub vital_type: String,
    pub value_numeric: Option<f64>,
    pub value_text: Option<String>,
    pub unit: String,
    pub measured_at: DateTime<Utc>,
    pub context: Option<String>,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// One lab test result with reference range.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LabResult {
    pub lab_id: String,
    pub test_name: String,
    pub value_numeric: f64,
    pub unit: String,
    pub reference_low: Option<f64>,
    pub reference_high: Option<f64>,
    pub measured_at: DateTime<Utc>,
    pub lab_name: Option<String>,
    pub notes: String,
    /// Optional FK to a row in `health_attachments`.
    pub attachment_id: Option<String>,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Encrypted attachment metadata. The actual binary lives at
/// `~/.local/share/lifeos/health_attachments/<attachment_id>.enc`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthAttachment {
    pub attachment_id: String,
    pub file_path: String,
    /// Categoría libre: `prescription`, `lab_pdf`, `xray`, `scan`,
    /// `consult_note`, `other`.
    pub file_type: String,
    pub description: Option<String>,
    pub related_event: Option<String>,
    pub sha256: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Aggregate snapshot returned by `MemoryPlaneManager::get_health_summary`.
///
/// This is what powers the "preparación para visita médica" coaching
/// flow: a single struct with everything a doctor would want to see
/// at a glance.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct HealthSummary {
    pub facts: Vec<HealthFact>,
    pub active_medications: Vec<Medication>,
    pub recent_vitals: Vec<Vital>,
    pub recent_labs: Vec<LabResult>,
    pub generated_at: DateTime<Utc>,
}

impl MemoryPlaneManager {
    // -----------------------------------------------------------------------
    // Health facts (alergias, condiciones, tipo de sangre, contactos)
    // -----------------------------------------------------------------------

    /// Add a permanent medical fact about the user.
    ///
    /// `notes` is encrypted at rest with the same default key as the
    /// rest of `memory.db`. An empty `notes` string skips the
    /// encryption step entirely. The optional `source_entry_id` links
    /// this fact to a narrative entry in `memory_entries` so the
    /// conversational context (where the user told Axi about the
    /// allergy) is recoverable.
    pub async fn add_health_fact(
        &self,
        fact_type: &str,
        label: &str,
        severity: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<HealthFact> {
        let fact_type = normalize_non_empty(fact_type).context("fact_type required")?;
        let label = normalize_non_empty(label).context("label required")?;
        let severity = severity
            .and_then(normalize_non_empty)
            .map(|s| s.to_lowercase());
        let notes_owned = notes.trim().to_string();

        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _digest) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let fact_id = format!("hfact-{}", Uuid::new_v4());
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let fact_id_clone = fact_id.clone();
        let fact_type_clone = fact_type.clone();
        let label_clone = label.clone();
        let severity_clone = severity.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO health_facts
                 (fact_id, fact_type, label, severity, notes_nonce_b64,
                  notes_ciphertext_b64, source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)",
                params![
                    fact_id_clone,
                    fact_type_clone,
                    label_clone,
                    severity_clone,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(HealthFact {
            fact_id,
            fact_type,
            label,
            severity,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// List all health facts of an optional `fact_type`. Notes are
    /// decrypted in this function (cheap — encrypted notes are tiny).
    pub async fn list_health_facts(
        &self,
        fact_type: Option<&str>,
    ) -> Result<Vec<HealthFact>> {
        let db_path = self.db_path.clone();
        let filter = fact_type.map(|s| s.to_string());
        let rows = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT fact_id, fact_type, label, severity, notes_nonce_b64,
                        notes_ciphertext_b64, source_entry_id, created_at, updated_at
                 FROM health_facts",
            );
            if filter.is_some() {
                sql.push_str(" WHERE fact_type = ?1");
            }
            sql.push_str(" ORDER BY created_at DESC");
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<HealthFactRaw> {
                Ok(HealthFactRaw {
                    fact_id: row.get(0)?,
                    fact_type: row.get(1)?,
                    label: row.get(2)?,
                    severity: row.get(3)?,
                    notes_nonce_b64: row.get(4)?,
                    notes_ciphertext_b64: row.get(5)?,
                    source_entry_id: row.get(6)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                })
            };
            let raws: Vec<HealthFactRaw> = if let Some(f) = filter {
                stmt.query_map(params![f], map_row)?.flatten().collect()
            } else {
                stmt.query_map([], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        let mut out = Vec::with_capacity(rows.len());
        for r in rows {
            let notes = match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                _ => String::new(),
            };
            out.push(HealthFact {
                fact_id: r.fact_id,
                fact_type: r.fact_type,
                label: r.label,
                severity: r.severity,
                notes,
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            });
        }
        Ok(out)
    }

    /// Delete a health fact. Returns `true` if a row was actually
    /// removed. Use with care — the auto-permanent contract for
    /// wellness data means this should only be called when the user
    /// explicitly asks ("ya no soy alérgico a X después del
    /// tratamiento de desensibilización").
    pub async fn delete_health_fact(&self, fact_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = fact_id.to_string();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute("DELETE FROM health_facts WHERE fact_id = ?1", params![id])?)
        })
        .await??;
        Ok(n > 0)
    }

    // -----------------------------------------------------------------------
    // Medications (history table)
    // -----------------------------------------------------------------------

    /// Start a new medication. If the user is already taking the same
    /// medication, the caller should `stop_medication(old_med_id)`
    /// first to close out the previous row — that is the history-table
    /// contract.
    #[allow(clippy::too_many_arguments)]
    pub async fn start_medication(
        &self,
        name: &str,
        dosage: &str,
        frequency: &str,
        condition: Option<&str>,
        prescribed_by: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<Medication> {
        let name = normalize_non_empty(name).context("name required")?;
        let dosage = normalize_non_empty(dosage).context("dosage required")?;
        let frequency = normalize_non_empty(frequency).context("frequency required")?;
        let condition = condition.and_then(normalize_non_empty);
        let prescribed_by = prescribed_by.and_then(normalize_non_empty);
        let notes_owned = notes.trim().to_string();

        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _digest) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let med_id = format!("hmed-{}", Uuid::new_v4());
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let med_id_clone = med_id.clone();
        let name_clone = name.clone();
        let dosage_clone = dosage.clone();
        let frequency_clone = frequency.clone();
        let condition_clone = condition.clone();
        let prescribed_by_clone = prescribed_by.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO health_medications
                 (med_id, name, dosage, frequency, condition, prescribed_by,
                  started_at, ended_at, notes_nonce_b64, notes_ciphertext_b64,
                  source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8, ?9, ?10, ?7, ?7)",
                params![
                    med_id_clone,
                    name_clone,
                    dosage_clone,
                    frequency_clone,
                    condition_clone,
                    prescribed_by_clone,
                    now_rfc,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(Medication {
            med_id,
            name,
            dosage,
            frequency,
            condition,
            prescribed_by,
            started_at: now,
            ended_at: None,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Mark a medication as ended (the user stopped taking it). Sets
    /// `ended_at = now` and updates `updated_at`. Returns `true` if
    /// the row was active and is now closed.
    pub async fn stop_medication(&self, med_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = med_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE health_medications
                 SET ended_at = ?1, updated_at = ?1
                 WHERE med_id = ?2 AND ended_at IS NULL",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    /// All medications the user is currently taking (ended_at IS NULL),
    /// most-recently-started first.
    pub async fn list_active_medications(&self) -> Result<Vec<Medication>> {
        self.list_medications_internal(true).await
    }

    /// Full medication history (active + stopped), most-recently-started first.
    pub async fn list_medication_history(&self) -> Result<Vec<Medication>> {
        self.list_medications_internal(false).await
    }

    async fn list_medications_internal(&self, active_only: bool) -> Result<Vec<Medication>> {
        let db_path = self.db_path.clone();
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let sql = if active_only {
                "SELECT med_id, name, dosage, frequency, condition, prescribed_by,
                        started_at, ended_at, notes_nonce_b64, notes_ciphertext_b64,
                        source_entry_id, created_at, updated_at
                 FROM health_medications
                 WHERE ended_at IS NULL
                 ORDER BY started_at DESC"
            } else {
                "SELECT med_id, name, dosage, frequency, condition, prescribed_by,
                        started_at, ended_at, notes_nonce_b64, notes_ciphertext_b64,
                        source_entry_id, created_at, updated_at
                 FROM health_medications
                 ORDER BY started_at DESC"
            };
            let mut stmt = db.prepare(sql)?;
            let raws: Vec<MedicationRaw> = stmt
                .query_map([], |row| {
                    Ok(MedicationRaw {
                        med_id: row.get(0)?,
                        name: row.get(1)?,
                        dosage: row.get(2)?,
                        frequency: row.get(3)?,
                        condition: row.get(4)?,
                        prescribed_by: row.get(5)?,
                        started_at: row.get(6)?,
                        ended_at: row.get(7)?,
                        notes_nonce_b64: row.get(8)?,
                        notes_ciphertext_b64: row.get(9)?,
                        source_entry_id: row.get(10)?,
                        created_at: row.get(11)?,
                        updated_at: row.get(12)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| Medication {
                med_id: r.med_id,
                name: r.name,
                dosage: r.dosage,
                frequency: r.frequency,
                condition: r.condition,
                prescribed_by: r.prescribed_by,
                started_at: parse_utc(&r.started_at),
                ended_at: r.ended_at.as_deref().map(parse_utc),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Vital signs (timeseries)
    // -----------------------------------------------------------------------

    /// Record a vital sign reading.
    ///
    /// `value_numeric` covers most cases. Use `value_text` only when
    /// the reading does not fit in a single number — but prefer the
    /// two-row pattern for blood pressure (one row for systolic, one
    /// for diastolic, both with the same `measured_at`).
    #[allow(clippy::too_many_arguments)]
    pub async fn record_vital(
        &self,
        vital_type: &str,
        value_numeric: Option<f64>,
        value_text: Option<&str>,
        unit: &str,
        measured_at: Option<DateTime<Utc>>,
        context: Option<&str>,
        source_entry_id: Option<&str>,
    ) -> Result<Vital> {
        let vital_type = normalize_non_empty(vital_type).context("vital_type required")?;
        let unit = normalize_non_empty(unit).context("unit required")?;
        let value_text = value_text.and_then(normalize_non_empty);
        let context = context.and_then(normalize_non_empty);
        if value_numeric.is_none() && value_text.is_none() {
            anyhow::bail!("vital must have value_numeric or value_text");
        }

        let measured = measured_at.unwrap_or_else(Utc::now);
        let measured_rfc = measured.to_rfc3339();
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let vital_id = format!("hvit-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let vital_id_clone = vital_id.clone();
        let vital_type_clone = vital_type.clone();
        let unit_clone = unit.clone();
        let value_text_clone = value_text.clone();
        let context_clone = context.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO health_vitals
                 (vital_id, vital_type, value_numeric, value_text, unit,
                  measured_at, context, source_entry_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    vital_id_clone,
                    vital_type_clone,
                    value_numeric,
                    value_text_clone,
                    unit_clone,
                    measured_rfc,
                    context_clone,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(Vital {
            vital_id,
            vital_type,
            value_numeric,
            value_text,
            unit,
            measured_at: measured,
            context,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
        })
    }

    /// Returns the timeseries for a given `vital_type`, newest first,
    /// limited to `limit` rows.
    pub async fn get_vitals_timeseries(
        &self,
        vital_type: &str,
        limit: usize,
    ) -> Result<Vec<Vital>> {
        let db_path = self.db_path.clone();
        let vital_type = vital_type.to_string();
        let limit = limit.clamp(1, 5000) as i64;
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT vital_id, vital_type, value_numeric, value_text, unit,
                        measured_at, context, source_entry_id, created_at
                 FROM health_vitals
                 WHERE vital_type = ?1
                 ORDER BY measured_at DESC
                 LIMIT ?2",
            )?;
            let raws: Vec<VitalRaw> = stmt
                .query_map(params![vital_type, limit], |row| {
                    Ok(VitalRaw {
                        vital_id: row.get(0)?,
                        vital_type: row.get(1)?,
                        value_numeric: row.get(2)?,
                        value_text: row.get(3)?,
                        unit: row.get(4)?,
                        measured_at: row.get(5)?,
                        context: row.get(6)?,
                        source_entry_id: row.get(7)?,
                        created_at: row.get(8)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| Vital {
                vital_id: r.vital_id,
                vital_type: r.vital_type,
                value_numeric: r.value_numeric,
                value_text: r.value_text,
                unit: r.unit,
                measured_at: parse_utc(&r.measured_at),
                context: r.context,
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Lab results
    // -----------------------------------------------------------------------

    /// Add a lab test result with optional reference range.
    #[allow(clippy::too_many_arguments)]
    pub async fn add_lab_result(
        &self,
        test_name: &str,
        value_numeric: f64,
        unit: &str,
        reference_low: Option<f64>,
        reference_high: Option<f64>,
        measured_at: Option<DateTime<Utc>>,
        lab_name: Option<&str>,
        notes: &str,
        attachment_id: Option<&str>,
        source_entry_id: Option<&str>,
    ) -> Result<LabResult> {
        let test_name = normalize_non_empty(test_name).context("test_name required")?;
        let unit = normalize_non_empty(unit).context("unit required")?;
        let lab_name = lab_name.and_then(normalize_non_empty);
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _digest) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let measured = measured_at.unwrap_or_else(Utc::now);
        let measured_rfc = measured.to_rfc3339();
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let lab_id = format!("hlab-{}", Uuid::new_v4());
        let attachment_owned = attachment_id.map(|s| s.to_string());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let lab_id_clone = lab_id.clone();
        let test_name_clone = test_name.clone();
        let unit_clone = unit.clone();
        let lab_name_clone = lab_name.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO health_lab_results
                 (lab_id, test_name, value_numeric, unit, reference_low,
                  reference_high, measured_at, lab_name, notes_nonce_b64,
                  notes_ciphertext_b64, attachment_id, source_entry_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    lab_id_clone,
                    test_name_clone,
                    value_numeric,
                    unit_clone,
                    reference_low,
                    reference_high,
                    measured_rfc,
                    lab_name_clone,
                    notes_nonce,
                    notes_cipher,
                    attachment_owned,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(LabResult {
            lab_id,
            test_name,
            value_numeric,
            unit,
            reference_low,
            reference_high,
            measured_at: measured,
            lab_name,
            notes: notes_owned,
            attachment_id: attachment_id.map(|s| s.to_string()),
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
        })
    }

    /// List lab results for an optional test name, newest first.
    pub async fn list_lab_results(
        &self,
        test_name: Option<&str>,
        limit: usize,
    ) -> Result<Vec<LabResult>> {
        let db_path = self.db_path.clone();
        let filter = test_name.map(|s| s.to_string());
        let limit = limit.clamp(1, 1000) as i64;
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT lab_id, test_name, value_numeric, unit, reference_low,
                        reference_high, measured_at, lab_name, notes_nonce_b64,
                        notes_ciphertext_b64, attachment_id, source_entry_id, created_at
                 FROM health_lab_results",
            );
            if filter.is_some() {
                sql.push_str(" WHERE test_name = ?1 ORDER BY measured_at DESC LIMIT ?2");
            } else {
                sql.push_str(" ORDER BY measured_at DESC LIMIT ?1");
            }
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<LabResultRaw> {
                Ok(LabResultRaw {
                    lab_id: row.get(0)?,
                    test_name: row.get(1)?,
                    value_numeric: row.get(2)?,
                    unit: row.get(3)?,
                    reference_low: row.get(4)?,
                    reference_high: row.get(5)?,
                    measured_at: row.get(6)?,
                    lab_name: row.get(7)?,
                    notes_nonce_b64: row.get(8)?,
                    notes_ciphertext_b64: row.get(9)?,
                    attachment_id: row.get(10)?,
                    source_entry_id: row.get(11)?,
                    created_at: row.get(12)?,
                })
            };
            let raws: Vec<LabResultRaw> = if let Some(f) = filter {
                stmt.query_map(params![f, limit], map_row)?.flatten().collect()
            } else {
                stmt.query_map(params![limit], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| LabResult {
                lab_id: r.lab_id,
                test_name: r.test_name,
                value_numeric: r.value_numeric,
                unit: r.unit,
                reference_low: r.reference_low,
                reference_high: r.reference_high,
                measured_at: parse_utc(&r.measured_at),
                lab_name: r.lab_name,
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                attachment_id: r.attachment_id,
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Encrypted attachments (recetas, radiografías, PDFs)
    // -----------------------------------------------------------------------

    /// Encrypt a binary blob and store it under
    /// `<data_dir>/health_attachments/<attachment_id>.enc`.
    ///
    /// Returns the metadata row for the new attachment. The plaintext
    /// is never written to disk — only the AES-GCM-SIV ciphertext.
    pub async fn add_health_attachment(
        &self,
        file_type: &str,
        description: Option<&str>,
        related_event: Option<&str>,
        plaintext_bytes: Vec<u8>,
        source_entry_id: Option<&str>,
    ) -> Result<HealthAttachment> {
        let file_type = normalize_non_empty(file_type).context("file_type required")?;
        let description = description.and_then(normalize_non_empty);
        let related_event = related_event.and_then(normalize_non_empty);
        if plaintext_bytes.is_empty() {
            anyhow::bail!("attachment is empty");
        }

        let attachment_id = format!("hatt-{}", Uuid::new_v4());
        let attachments_dir = self.data_dir.join("health_attachments");
        std::fs::create_dir_all(&attachments_dir)
            .context("failed to create health_attachments directory")?;
        let file_path = attachments_dir.join(format!("{}.enc", attachment_id));

        // SHA256 of plaintext for integrity check on read.
        let sha256 = format!("{:x}", Sha256::digest(&plaintext_bytes));

        // Encrypt the binary blob.
        let cipher = cipher()?;
        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(nonce, plaintext_bytes.as_ref())
            .map_err(|e| anyhow::anyhow!("attachment encryption failed: {}", e))?;
        let nonce_b64 = B64.encode(nonce_bytes);

        // Write to disk (cipher only — never the plaintext).
        let file_path_str = file_path.to_string_lossy().to_string();
        tokio::fs::write(&file_path, &ciphertext)
            .await
            .with_context(|| format!("failed to write attachment to {}", file_path_str))?;

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let attachment_id_clone = attachment_id.clone();
        let file_path_clone = file_path_str.clone();
        let file_type_clone = file_type.clone();
        let description_clone = description.clone();
        let related_event_clone = related_event.clone();
        let sha256_clone = sha256.clone();
        let nonce_b64_clone = nonce_b64.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO health_attachments
                 (attachment_id, file_path, file_type, description, related_event,
                  sha256, nonce_b64, source_entry_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    attachment_id_clone,
                    file_path_clone,
                    file_type_clone,
                    description_clone,
                    related_event_clone,
                    sha256_clone,
                    nonce_b64_clone,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(HealthAttachment {
            attachment_id,
            file_path: file_path_str,
            file_type,
            description,
            related_event,
            sha256,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
        })
    }

    /// Decrypt and return the plaintext of an attachment by id.
    /// Verifies the SHA256 — bails if the file has been tampered with.
    pub async fn get_health_attachment(&self, attachment_id: &str) -> Result<Vec<u8>> {
        let db_path = self.db_path.clone();
        let id = attachment_id.to_string();
        let (file_path, nonce_b64, expected_sha) = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let row: (String, String, String) = db.query_row(
                "SELECT file_path, nonce_b64, sha256 FROM health_attachments
                 WHERE attachment_id = ?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            Ok::<_, anyhow::Error>(row)
        })
        .await??;

        let ciphertext = tokio::fs::read(&file_path)
            .await
            .with_context(|| format!("failed to read attachment file {}", file_path))?;

        let cipher = cipher()?;
        let nonce_bytes = B64
            .decode(nonce_b64.as_bytes())
            .context("invalid attachment nonce encoding")?;
        if nonce_bytes.len() != 12 {
            anyhow::bail!("invalid attachment nonce length");
        }
        let nonce = Nonce::from_slice(&nonce_bytes);
        let plaintext = cipher
            .decrypt(nonce, ciphertext.as_ref())
            .map_err(|e| anyhow::anyhow!("attachment decryption failed: {}", e))?;

        let actual_sha = format!("{:x}", Sha256::digest(&plaintext));
        if actual_sha != expected_sha {
            anyhow::bail!("attachment integrity check failed");
        }
        Ok(plaintext)
    }

    /// List attachment metadata (NOT the binary contents).
    pub async fn list_health_attachments(
        &self,
        file_type: Option<&str>,
    ) -> Result<Vec<HealthAttachment>> {
        let db_path = self.db_path.clone();
        let filter = file_type.map(|s| s.to_string());
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT attachment_id, file_path, file_type, description,
                        related_event, sha256, nonce_b64, source_entry_id, created_at
                 FROM health_attachments",
            );
            if filter.is_some() {
                sql.push_str(" WHERE file_type = ?1");
            }
            sql.push_str(" ORDER BY created_at DESC");
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<HealthAttachment> {
                Ok(HealthAttachment {
                    attachment_id: row.get(0)?,
                    file_path: row.get(1)?,
                    file_type: row.get(2)?,
                    description: row.get(3)?,
                    related_event: row.get(4)?,
                    sha256: row.get(5)?,
                    // skip nonce — caller does not need it
                    source_entry_id: row.get(7)?,
                    created_at: parse_utc(&row.get::<_, String>(8)?),
                })
            };
            let raws: Vec<HealthAttachment> = if let Some(f) = filter {
                stmt.query_map(params![f], map_row)?.flatten().collect()
            } else {
                stmt.query_map([], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;
        Ok(raws)
    }

    // -----------------------------------------------------------------------
    // Health summary aggregator
    // -----------------------------------------------------------------------

    /// Aggregate health snapshot for the user.
    ///
    /// Combines: all health_facts, all active medications, the last
    /// `vitals_per_type` vitals per known vital_type, and the last
    /// `recent_labs_count` lab results. This is what powers the
    /// "preparación para visita médica" coaching flow — one struct
    /// the doctor can review at a glance.
    pub async fn get_health_summary(
        &self,
        vitals_per_type: usize,
        recent_labs_count: usize,
    ) -> Result<HealthSummary> {
        let facts = self.list_health_facts(None).await?;
        let active_medications = self.list_active_medications().await?;

        // Pull recent vitals across all types. We grab the union of
        // every distinct vital_type and then take the most recent N
        // per type so the timeseries summary is balanced.
        let known_types: Vec<String> = {
            let db_path = self.db_path.clone();
            tokio::task::spawn_blocking(move || -> Result<Vec<String>> {
                let db = Self::open_db(&db_path)?;
                let mut stmt =
                    db.prepare("SELECT DISTINCT vital_type FROM health_vitals")?;
                let types: Vec<String> = stmt
                    .query_map([], |r| r.get::<_, String>(0))?
                    .flatten()
                    .collect();
                Ok(types)
            })
            .await??
        };

        let mut recent_vitals = Vec::new();
        for t in known_types {
            let mut series = self.get_vitals_timeseries(&t, vitals_per_type).await?;
            recent_vitals.append(&mut series);
        }

        let recent_labs = self.list_lab_results(None, recent_labs_count).await?;

        Ok(HealthSummary {
            facts,
            active_medications,
            recent_vitals,
            recent_labs,
            generated_at: Utc::now(),
        })
    }
}

// -- Private raw row types (one per side-table) used to keep the
//    SQLite-facing structs clearly separated from the public Rust API.

struct HealthFactRaw {
    fact_id: String,
    fact_type: String,
    label: String,
    severity: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct MedicationRaw {
    med_id: String,
    name: String,
    dosage: String,
    frequency: String,
    condition: Option<String>,
    prescribed_by: Option<String>,
    started_at: String,
    ended_at: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct VitalRaw {
    vital_id: String,
    vital_type: String,
    value_numeric: Option<f64>,
    value_text: Option<String>,
    unit: String,
    measured_at: String,
    context: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
}

struct LabResultRaw {
    lab_id: String,
    test_name: String,
    value_numeric: f64,
    unit: String,
    reference_low: Option<f64>,
    reference_high: Option<f64>,
    measured_at: String,
    lab_name: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    attachment_id: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
}

// ============================================================================
// Fase BI.7 — Crecimiento personal (Vida Plena)
// ============================================================================

/// Reading status for a book in `reading_log`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BookStatus {
    Wishlist,
    Reading,
    Finished,
    Abandoned,
}

impl BookStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Wishlist => "wishlist",
            Self::Reading => "reading",
            Self::Finished => "finished",
            Self::Abandoned => "abandoned",
        }
    }
    pub fn parse(s: &str) -> Result<Self> {
        match s.trim().to_lowercase().as_str() {
            "wishlist" => Ok(Self::Wishlist),
            "reading" => Ok(Self::Reading),
            "finished" => Ok(Self::Finished),
            "abandoned" => Ok(Self::Abandoned),
            other => anyhow::bail!("invalid book status: {}", other),
        }
    }
}

/// One book in the reading log.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Book {
    pub book_id: String,
    pub title: String,
    pub author: Option<String>,
    pub isbn: Option<String>,
    pub status: BookStatus,
    pub rating_1_5: Option<u8>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    /// Highlights, takeaways, notes — encrypted at rest. Empty when none.
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// A habit the user wants to build (meditate, read, run, etc.).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Habit {
    pub habit_id: String,
    pub name: String,
    pub description: Option<String>,
    /// Free-form: `daily`, `weekly:3`, `custom:MO,WE,FR`.
    pub frequency: String,
    pub started_at: DateTime<Utc>,
    pub active: bool,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One day's check-in for a habit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HabitCheckIn {
    pub log_id: String,
    pub habit_id: String,
    pub completed: bool,
    /// `YYYY-MM-DD` (local date for the user).
    pub logged_for_date: String,
    pub notes: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Status of a long-term growth goal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GoalStatus {
    Active,
    Paused,
    Achieved,
    Abandoned,
}

impl GoalStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Achieved => "achieved",
            Self::Abandoned => "abandoned",
        }
    }
    pub fn parse(s: &str) -> Result<Self> {
        match s.trim().to_lowercase().as_str() {
            "active" => Ok(Self::Active),
            "paused" => Ok(Self::Paused),
            "achieved" => Ok(Self::Achieved),
            "abandoned" => Ok(Self::Abandoned),
            other => anyhow::bail!("invalid goal status: {}", other),
        }
    }
}

/// A long-term growth goal (carrera, finanzas, salud, lo que sea).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GrowthGoal {
    pub goal_id: String,
    pub name: String,
    pub description: Option<String>,
    /// Optional ISO-8601 deadline. Free-form because some goals have
    /// soft deadlines ("este año") and others are precise.
    pub deadline: Option<String>,
    /// Progress 0..100. Capped at insert/update.
    pub progress_pct: u8,
    pub status: GoalStatus,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Aggregate snapshot returned by `MemoryPlaneManager::get_growth_summary`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GrowthSummary {
    pub currently_reading: Vec<Book>,
    pub recently_finished: Vec<Book>,
    pub active_habits: Vec<Habit>,
    pub habit_streak_30d: Vec<HabitStreak>,
    pub active_goals: Vec<GrowthGoal>,
    pub generated_at: DateTime<Utc>,
}

/// Per-habit completion stats over the last N days.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HabitStreak {
    pub habit_id: String,
    pub habit_name: String,
    pub completed_days: u32,
    pub total_days: u32,
}

impl MemoryPlaneManager {
    // -----------------------------------------------------------------------
    // Reading log
    // -----------------------------------------------------------------------

    /// Add a book to the reading log. `status` defaults to `wishlist`
    /// if the user only knows they want to read it.
    #[allow(clippy::too_many_arguments)]
    pub async fn add_book(
        &self,
        title: &str,
        author: Option<&str>,
        isbn: Option<&str>,
        status: BookStatus,
        rating_1_5: Option<u8>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<Book> {
        let title = normalize_non_empty(title).context("title required")?;
        let author = author.and_then(normalize_non_empty);
        let isbn = isbn.and_then(normalize_non_empty);
        let rating_1_5 = match rating_1_5 {
            Some(r) if (1..=5).contains(&r) => Some(r),
            Some(_) => anyhow::bail!("rating must be 1..=5"),
            None => None,
        };
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let book_id = format!("book-{}", Uuid::new_v4());
        let started_at = if status == BookStatus::Reading {
            Some(now_rfc.clone())
        } else {
            None
        };
        let finished_at = if status == BookStatus::Finished {
            Some(now_rfc.clone())
        } else {
            None
        };
        let status_str = status.as_str().to_string();
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let book_id_clone = book_id.clone();
        let title_clone = title.clone();
        let author_clone = author.clone();
        let isbn_clone = isbn.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO reading_log
                 (book_id, title, author, isbn, status, rating_1_5,
                  started_at, finished_at, notes_nonce_b64, notes_ciphertext_b64,
                  source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)",
                params![
                    book_id_clone,
                    title_clone,
                    author_clone,
                    isbn_clone,
                    status_str,
                    rating_1_5.map(|r| r as i32),
                    started_at,
                    finished_at,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(Book {
            book_id,
            title,
            author,
            isbn,
            status,
            rating_1_5,
            started_at: if status == BookStatus::Reading {
                Some(now)
            } else {
                None
            },
            finished_at: if status == BookStatus::Finished {
                Some(now)
            } else {
                None
            },
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Update the status of a book. Side-effects:
    /// - Setting `Reading` populates `started_at` if not already set.
    /// - Setting `Finished` or `Abandoned` populates `finished_at`.
    /// - `Wishlist` clears `started_at` and `finished_at`.
    pub async fn update_book_status(
        &self,
        book_id: &str,
        new_status: BookStatus,
        rating_1_5: Option<u8>,
    ) -> Result<bool> {
        if let Some(r) = rating_1_5 {
            if !(1..=5).contains(&r) {
                anyhow::bail!("rating must be 1..=5");
            }
        }
        let db_path = self.db_path.clone();
        let id = book_id.to_string();
        let now = Utc::now().to_rfc3339();
        let status_str = new_status.as_str().to_string();

        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            let n = match new_status {
                BookStatus::Reading => db.execute(
                    "UPDATE reading_log
                     SET status = ?1,
                         started_at = COALESCE(started_at, ?2),
                         finished_at = NULL,
                         rating_1_5 = COALESCE(?3, rating_1_5),
                         updated_at = ?2
                     WHERE book_id = ?4",
                    params![status_str, now, rating_1_5.map(|r| r as i32), id],
                )?,
                BookStatus::Finished | BookStatus::Abandoned => db.execute(
                    "UPDATE reading_log
                     SET status = ?1,
                         finished_at = ?2,
                         rating_1_5 = COALESCE(?3, rating_1_5),
                         updated_at = ?2
                     WHERE book_id = ?4",
                    params![status_str, now, rating_1_5.map(|r| r as i32), id],
                )?,
                BookStatus::Wishlist => db.execute(
                    "UPDATE reading_log
                     SET status = ?1,
                         started_at = NULL,
                         finished_at = NULL,
                         rating_1_5 = COALESCE(?3, rating_1_5),
                         updated_at = ?2
                     WHERE book_id = ?4",
                    params![status_str, now, rating_1_5.map(|r| r as i32), id],
                )?,
            };
            Ok(n)
        })
        .await??;
        Ok(n > 0)
    }

    /// List books, optionally filtered by status.
    pub async fn list_books(&self, status: Option<BookStatus>) -> Result<Vec<Book>> {
        let db_path = self.db_path.clone();
        let filter = status.map(|s| s.as_str().to_string());
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT book_id, title, author, isbn, status, rating_1_5,
                        started_at, finished_at, notes_nonce_b64, notes_ciphertext_b64,
                        source_entry_id, created_at, updated_at
                 FROM reading_log",
            );
            if filter.is_some() {
                sql.push_str(" WHERE status = ?1");
            }
            sql.push_str(" ORDER BY updated_at DESC");
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<BookRaw> {
                Ok(BookRaw {
                    book_id: row.get(0)?,
                    title: row.get(1)?,
                    author: row.get(2)?,
                    isbn: row.get(3)?,
                    status: row.get(4)?,
                    rating_1_5: row.get(5)?,
                    started_at: row.get(6)?,
                    finished_at: row.get(7)?,
                    notes_nonce_b64: row.get(8)?,
                    notes_ciphertext_b64: row.get(9)?,
                    source_entry_id: row.get(10)?,
                    created_at: row.get(11)?,
                    updated_at: row.get(12)?,
                })
            };
            let raws: Vec<BookRaw> = if let Some(f) = filter {
                stmt.query_map(params![f], map_row)?.flatten().collect()
            } else {
                stmt.query_map([], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| Book {
                book_id: r.book_id,
                title: r.title,
                author: r.author,
                isbn: r.isbn,
                status: BookStatus::parse(&r.status).unwrap_or(BookStatus::Wishlist),
                rating_1_5: r.rating_1_5.map(|n| n as u8),
                started_at: r.started_at.as_deref().map(parse_utc),
                finished_at: r.finished_at.as_deref().map(parse_utc),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Habits
    // -----------------------------------------------------------------------

    /// Create a new habit.
    pub async fn add_habit(
        &self,
        name: &str,
        description: Option<&str>,
        frequency: &str,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<Habit> {
        let name = normalize_non_empty(name).context("name required")?;
        let description = description.and_then(normalize_non_empty);
        let frequency = normalize_non_empty(frequency).context("frequency required")?;
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let habit_id = format!("habit-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let habit_id_clone = habit_id.clone();
        let name_clone = name.clone();
        let description_clone = description.clone();
        let frequency_clone = frequency.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO habits
                 (habit_id, name, description, frequency, started_at, active,
                  notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?5, ?5)",
                params![
                    habit_id_clone,
                    name_clone,
                    description_clone,
                    frequency_clone,
                    now_rfc,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(Habit {
            habit_id,
            name,
            description,
            frequency,
            started_at: now,
            active: true,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Mark a habit as inactive (the user gave it up). Returns true if
    /// the row was active and is now closed.
    pub async fn deactivate_habit(&self, habit_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = habit_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE habits SET active = 0, updated_at = ?1
                 WHERE habit_id = ?2 AND active = 1",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    /// Record (or overwrite) a habit check-in for a specific date.
    /// `logged_for_date` is `YYYY-MM-DD` in the user's local timezone —
    /// the caller is responsible for picking the right date.
    pub async fn log_habit_checkin(
        &self,
        habit_id: &str,
        completed: bool,
        logged_for_date: &str,
        notes: Option<&str>,
    ) -> Result<HabitCheckIn> {
        let habit_id = normalize_non_empty(habit_id).context("habit_id required")?;
        let logged_for_date =
            normalize_non_empty(logged_for_date).context("logged_for_date required")?;
        let notes_owned = notes.and_then(normalize_non_empty);

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let log_id = format!("hlog-{}", Uuid::new_v4());

        let db_path = self.db_path.clone();
        let log_id_clone = log_id.clone();
        let habit_id_clone = habit_id.clone();
        let date_clone = logged_for_date.clone();
        let notes_clone = notes_owned.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            // INSERT OR REPLACE on the (habit_id, logged_for_date)
            // unique constraint — checking in twice the same day just
            // overwrites the latest value.
            db.execute(
                "INSERT INTO habit_log
                 (log_id, habit_id, completed, logged_for_date, notes, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(habit_id, logged_for_date) DO UPDATE SET
                     completed = excluded.completed,
                     notes = excluded.notes,
                     created_at = excluded.created_at",
                params![
                    log_id_clone,
                    habit_id_clone,
                    completed as i32,
                    date_clone,
                    notes_clone,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(HabitCheckIn {
            log_id,
            habit_id,
            completed,
            logged_for_date,
            notes: notes_owned,
            created_at: now,
        })
    }

    /// All habits, optionally filtered to active-only.
    pub async fn list_habits(&self, active_only: bool) -> Result<Vec<Habit>> {
        let db_path = self.db_path.clone();
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let sql = if active_only {
                "SELECT habit_id, name, description, frequency, started_at, active,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM habits WHERE active = 1 ORDER BY created_at DESC"
            } else {
                "SELECT habit_id, name, description, frequency, started_at, active,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM habits ORDER BY created_at DESC"
            };
            let mut stmt = db.prepare(sql)?;
            let raws: Vec<HabitRaw> = stmt
                .query_map([], |row| {
                    Ok(HabitRaw {
                        habit_id: row.get(0)?,
                        name: row.get(1)?,
                        description: row.get(2)?,
                        frequency: row.get(3)?,
                        started_at: row.get(4)?,
                        active: row.get::<_, i32>(5)? != 0,
                        notes_nonce_b64: row.get(6)?,
                        notes_ciphertext_b64: row.get(7)?,
                        source_entry_id: row.get(8)?,
                        created_at: row.get(9)?,
                        updated_at: row.get(10)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| Habit {
                habit_id: r.habit_id,
                name: r.name,
                description: r.description,
                frequency: r.frequency,
                started_at: parse_utc(&r.started_at),
                active: r.active,
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    /// Compute completion stats for an active habit over the last N days.
    /// Counts the number of `completed = 1` rows over the window
    /// `[today - days + 1, today]` in **lexicographic** order on
    /// `logged_for_date`. Caller passes `today` as a `YYYY-MM-DD`
    /// string in their local timezone.
    pub async fn get_habit_streak(
        &self,
        habit_id: &str,
        today: &str,
        days: u32,
    ) -> Result<HabitStreak> {
        if days == 0 {
            anyhow::bail!("days must be >= 1");
        }
        let db_path = self.db_path.clone();
        let id = habit_id.to_string();
        // Compute the start date by subtracting (days-1) days from `today`.
        // We do it in Rust because SQLite date arithmetic on text dates
        // is brittle and we want the caller's local date semantics.
        let today_date = chrono::NaiveDate::parse_from_str(today, "%Y-%m-%d")
            .with_context(|| format!("invalid today date '{}'", today))?;
        let start_date = today_date
            .checked_sub_signed(chrono::Duration::days((days - 1) as i64))
            .context("date underflow")?
            .format("%Y-%m-%d")
            .to_string();
        let today_owned = today.to_string();
        let id_for_query = id.clone();

        let (habit_name, completed): (String, u32) =
            tokio::task::spawn_blocking(move || -> Result<(String, u32)> {
                let db = Self::open_db(&db_path)?;
                let name: String = db.query_row(
                    "SELECT name FROM habits WHERE habit_id = ?1",
                    params![id_for_query],
                    |r| r.get(0),
                )?;
                let count: i64 = db.query_row(
                    "SELECT COUNT(*) FROM habit_log
                     WHERE habit_id = ?1 AND completed = 1
                       AND logged_for_date BETWEEN ?2 AND ?3",
                    params![id, start_date, today_owned],
                    |r| r.get(0),
                )?;
                Ok((name, count.max(0) as u32))
            })
            .await??;

        Ok(HabitStreak {
            habit_id: habit_id.to_string(),
            habit_name,
            completed_days: completed,
            total_days: days,
        })
    }

    // -----------------------------------------------------------------------
    // Growth goals
    // -----------------------------------------------------------------------

    pub async fn add_growth_goal(
        &self,
        name: &str,
        description: Option<&str>,
        deadline: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<GrowthGoal> {
        let name = normalize_non_empty(name).context("name required")?;
        let description = description.and_then(normalize_non_empty);
        let deadline = deadline.and_then(normalize_non_empty);
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let goal_id = format!("goal-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let goal_id_clone = goal_id.clone();
        let name_clone = name.clone();
        let description_clone = description.clone();
        let deadline_clone = deadline.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO growth_goals
                 (goal_id, name, description, deadline, progress_pct, status,
                  notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, 0, 'active', ?5, ?6, ?7, ?8, ?8)",
                params![
                    goal_id_clone,
                    name_clone,
                    description_clone,
                    deadline_clone,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(GrowthGoal {
            goal_id,
            name,
            description,
            deadline,
            progress_pct: 0,
            status: GoalStatus::Active,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Update progress + optionally status of a goal. Progress is
    /// clamped to 0..=100. Setting progress to 100 also flips status
    /// to `Achieved` automatically (unless the caller specifies a
    /// different one).
    pub async fn update_growth_goal_progress(
        &self,
        goal_id: &str,
        progress_pct: u8,
        new_status: Option<GoalStatus>,
    ) -> Result<bool> {
        let progress_pct = progress_pct.min(100);
        let auto_status = if progress_pct >= 100 {
            GoalStatus::Achieved
        } else {
            GoalStatus::Active
        };
        let effective_status = new_status.unwrap_or(auto_status);
        let db_path = self.db_path.clone();
        let id = goal_id.to_string();
        let now = Utc::now().to_rfc3339();
        let status_str = effective_status.as_str().to_string();

        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE growth_goals
                 SET progress_pct = ?1, status = ?2, updated_at = ?3
                 WHERE goal_id = ?4",
                params![progress_pct as i32, status_str, now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    /// List growth goals, optionally filtered by status.
    pub async fn list_growth_goals(
        &self,
        status: Option<GoalStatus>,
    ) -> Result<Vec<GrowthGoal>> {
        let db_path = self.db_path.clone();
        let filter = status.map(|s| s.as_str().to_string());
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT goal_id, name, description, deadline, progress_pct, status,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM growth_goals",
            );
            if filter.is_some() {
                sql.push_str(" WHERE status = ?1");
            }
            sql.push_str(" ORDER BY updated_at DESC");
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<GrowthGoalRaw> {
                Ok(GrowthGoalRaw {
                    goal_id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    deadline: row.get(3)?,
                    progress_pct: row.get(4)?,
                    status: row.get(5)?,
                    notes_nonce_b64: row.get(6)?,
                    notes_ciphertext_b64: row.get(7)?,
                    source_entry_id: row.get(8)?,
                    created_at: row.get(9)?,
                    updated_at: row.get(10)?,
                })
            };
            let raws: Vec<GrowthGoalRaw> = if let Some(f) = filter {
                stmt.query_map(params![f], map_row)?.flatten().collect()
            } else {
                stmt.query_map([], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| GrowthGoal {
                goal_id: r.goal_id,
                name: r.name,
                description: r.description,
                deadline: r.deadline,
                progress_pct: r.progress_pct.clamp(0, 100) as u8,
                status: GoalStatus::parse(&r.status).unwrap_or(GoalStatus::Active),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Growth summary aggregator
    // -----------------------------------------------------------------------

    /// Aggregate growth snapshot. Used by `growth_summary` Telegram
    /// tool and the future BI.8 narrative coaching layer.
    pub async fn get_growth_summary(
        &self,
        recent_finished_limit: usize,
        streak_today: &str,
        streak_window_days: u32,
    ) -> Result<GrowthSummary> {
        let currently_reading = self.list_books(Some(BookStatus::Reading)).await?;
        let mut recently_finished = self.list_books(Some(BookStatus::Finished)).await?;
        recently_finished.truncate(recent_finished_limit);

        let active_habits = self.list_habits(true).await?;
        let mut habit_streak_30d = Vec::with_capacity(active_habits.len());
        for h in &active_habits {
            // Best-effort — if streak fails for one habit we still
            // return the rest of the summary.
            if let Ok(streak) = self
                .get_habit_streak(&h.habit_id, streak_today, streak_window_days)
                .await
            {
                habit_streak_30d.push(streak);
            }
        }

        let active_goals = self.list_growth_goals(Some(GoalStatus::Active)).await?;

        Ok(GrowthSummary {
            currently_reading,
            recently_finished,
            active_habits,
            habit_streak_30d,
            active_goals,
            generated_at: Utc::now(),
        })
    }
}

// -- Private raw row types for BI.7 -------------------------------------------

struct BookRaw {
    book_id: String,
    title: String,
    author: Option<String>,
    isbn: Option<String>,
    status: String,
    rating_1_5: Option<i32>,
    started_at: Option<String>,
    finished_at: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct HabitRaw {
    habit_id: String,
    name: String,
    description: Option<String>,
    frequency: String,
    started_at: String,
    active: bool,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct GrowthGoalRaw {
    goal_id: String,
    name: String,
    description: Option<String>,
    deadline: Option<String>,
    progress_pct: i32,
    status: String,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

// ============================================================================
// Fase BI.5 — Ejercicio (Vida Plena)
// ============================================================================

/// One piece of equipment (or environment) the user has access to.
///
/// Used by the routine generator to constrain proposed exercises to
/// what the user can actually execute. Examples: mancuernas
/// ajustables 5-25kg, banca plana, liga de resistencia media, acceso
/// a gimnasio (con todo), 4m² de espacio libre en casa.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExerciseInventoryItem {
    pub item_id: String,
    pub item_name: String,
    /// Categoría libre. Convención sugerida: `free_weights`, `cardio`,
    /// `bands`, `machine`, `gym_access`, `space`, `other`.
    pub item_category: String,
    pub quantity: u32,
    pub notes: Option<String>,
    pub active: bool,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One exercise inside an `ExercisePlan`. The plan stores a JSON
/// array of these as `exercises_json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExercisePlanItem {
    /// Free text: "press de banca con mancuernas".
    pub name: String,
    /// Optional sets × reps spec. We keep it as text so the plan can
    /// also describe time-based exercises ("plancha 60s").
    pub sets_reps: Option<String>,
    /// Optional rest in seconds.
    pub rest_secs: Option<u32>,
    pub notes: Option<String>,
}

/// A saved exercise routine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExercisePlan {
    pub plan_id: String,
    pub name: String,
    pub description: Option<String>,
    /// Free text: 'fuerza', 'cardio', 'flexibilidad', 'rehab', etc.
    pub goal: Option<String>,
    pub sessions_per_week: Option<u32>,
    pub minutes_per_session: Option<u32>,
    pub exercises: Vec<ExercisePlanItem>,
    pub source: Option<String>,
    pub active: bool,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One completed exercise session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExerciseSession {
    pub session_id: String,
    pub plan_id: Option<String>,
    /// Convención: `strength`, `cardio`, `flexibility`, `sport`, `mixed`.
    pub session_type: String,
    pub description: String,
    pub duration_min: u32,
    /// Rate of Perceived Exertion 1-10. Optional because not every
    /// session is rated.
    pub rpe_1_10: Option<u8>,
    pub notes: String,
    pub completed_at: DateTime<Utc>,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Aggregate snapshot returned by `get_exercise_summary`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ExerciseSummary {
    pub inventory: Vec<ExerciseInventoryItem>,
    pub active_plans: Vec<ExercisePlan>,
    pub recent_sessions: Vec<ExerciseSession>,
    pub sessions_last_7_days: u32,
    pub sessions_last_30_days: u32,
    pub total_minutes_last_30_days: u32,
    pub generated_at: DateTime<Utc>,
}

impl MemoryPlaneManager {
    // -----------------------------------------------------------------------
    // Exercise inventory
    // -----------------------------------------------------------------------

    pub async fn add_exercise_inventory_item(
        &self,
        item_name: &str,
        item_category: &str,
        quantity: u32,
        notes: Option<&str>,
        source_entry_id: Option<&str>,
    ) -> Result<ExerciseInventoryItem> {
        let item_name = normalize_non_empty(item_name).context("item_name required")?;
        let item_category =
            normalize_non_empty(item_category).context("item_category required")?;
        let notes = notes.and_then(normalize_non_empty);

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let item_id = format!("einv-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let item_id_clone = item_id.clone();
        let item_name_clone = item_name.clone();
        let item_category_clone = item_category.clone();
        let notes_clone = notes.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO exercise_inventory
                 (item_id, item_name, item_category, quantity, notes, active,
                  source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?7)",
                params![
                    item_id_clone,
                    item_name_clone,
                    item_category_clone,
                    quantity as i32,
                    notes_clone,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(ExerciseInventoryItem {
            item_id,
            item_name,
            item_category,
            quantity,
            notes,
            active: true,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Mark an inventory item as no longer available (vendido, roto,
    /// regalado). Returns true if the row was active.
    pub async fn deactivate_inventory_item(&self, item_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = item_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE exercise_inventory SET active = 0, updated_at = ?1
                 WHERE item_id = ?2 AND active = 1",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    /// List inventory items. `active_only` filters out deactivated rows.
    pub async fn list_exercise_inventory(
        &self,
        active_only: bool,
    ) -> Result<Vec<ExerciseInventoryItem>> {
        let db_path = self.db_path.clone();
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let sql = if active_only {
                "SELECT item_id, item_name, item_category, quantity, notes,
                        active, source_entry_id, created_at, updated_at
                 FROM exercise_inventory WHERE active = 1
                 ORDER BY item_category, item_name"
            } else {
                "SELECT item_id, item_name, item_category, quantity, notes,
                        active, source_entry_id, created_at, updated_at
                 FROM exercise_inventory
                 ORDER BY item_category, item_name"
            };
            let mut stmt = db.prepare(sql)?;
            let raws: Vec<ExerciseInventoryRaw> = stmt
                .query_map([], |row| {
                    Ok(ExerciseInventoryRaw {
                        item_id: row.get(0)?,
                        item_name: row.get(1)?,
                        item_category: row.get(2)?,
                        quantity: row.get(3)?,
                        notes: row.get(4)?,
                        active: row.get::<_, i32>(5)? != 0,
                        source_entry_id: row.get(6)?,
                        created_at: row.get(7)?,
                        updated_at: row.get(8)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| ExerciseInventoryItem {
                item_id: r.item_id,
                item_name: r.item_name,
                item_category: r.item_category,
                quantity: r.quantity.max(0) as u32,
                notes: r.notes,
                active: r.active,
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Exercise plans
    // -----------------------------------------------------------------------

    /// Create a new exercise plan with the given exercises.
    #[allow(clippy::too_many_arguments)]
    pub async fn add_exercise_plan(
        &self,
        name: &str,
        description: Option<&str>,
        goal: Option<&str>,
        sessions_per_week: Option<u32>,
        minutes_per_session: Option<u32>,
        exercises: Vec<ExercisePlanItem>,
        source: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<ExercisePlan> {
        let name = normalize_non_empty(name).context("name required")?;
        let description = description.and_then(normalize_non_empty);
        let goal = goal.and_then(normalize_non_empty);
        let source = source.and_then(normalize_non_empty);
        if exercises.is_empty() {
            anyhow::bail!("plan must contain at least one exercise");
        }
        let exercises_json = serde_json::to_string(&exercises)
            .context("failed to serialise plan exercises")?;
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let plan_id = format!("eplan-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let plan_id_clone = plan_id.clone();
        let name_clone = name.clone();
        let description_clone = description.clone();
        let goal_clone = goal.clone();
        let source_clone = source.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO exercise_plans
                 (plan_id, name, description, goal, sessions_per_week,
                  minutes_per_session, exercises_json, source, active,
                  notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, ?10, ?11, ?12, ?12)",
                params![
                    plan_id_clone,
                    name_clone,
                    description_clone,
                    goal_clone,
                    sessions_per_week.map(|n| n as i32),
                    minutes_per_session.map(|n| n as i32),
                    exercises_json,
                    source_clone,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(ExercisePlan {
            plan_id,
            name,
            description,
            goal,
            sessions_per_week,
            minutes_per_session,
            exercises,
            source,
            active: true,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Mark a plan as inactive (the user moved on or it was a one-off).
    pub async fn deactivate_exercise_plan(&self, plan_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = plan_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE exercise_plans SET active = 0, updated_at = ?1
                 WHERE plan_id = ?2 AND active = 1",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    pub async fn list_exercise_plans(&self, active_only: bool) -> Result<Vec<ExercisePlan>> {
        let db_path = self.db_path.clone();
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let sql = if active_only {
                "SELECT plan_id, name, description, goal, sessions_per_week,
                        minutes_per_session, exercises_json, source, active,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM exercise_plans WHERE active = 1
                 ORDER BY created_at DESC"
            } else {
                "SELECT plan_id, name, description, goal, sessions_per_week,
                        minutes_per_session, exercises_json, source, active,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM exercise_plans
                 ORDER BY created_at DESC"
            };
            let mut stmt = db.prepare(sql)?;
            let raws: Vec<ExercisePlanRaw> = stmt
                .query_map([], |row| {
                    Ok(ExercisePlanRaw {
                        plan_id: row.get(0)?,
                        name: row.get(1)?,
                        description: row.get(2)?,
                        goal: row.get(3)?,
                        sessions_per_week: row.get(4)?,
                        minutes_per_session: row.get(5)?,
                        exercises_json: row.get(6)?,
                        source: row.get(7)?,
                        active: row.get::<_, i32>(8)? != 0,
                        notes_nonce_b64: row.get(9)?,
                        notes_ciphertext_b64: row.get(10)?,
                        source_entry_id: row.get(11)?,
                        created_at: row.get(12)?,
                        updated_at: row.get(13)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| ExercisePlan {
                plan_id: r.plan_id,
                name: r.name,
                description: r.description,
                goal: r.goal,
                sessions_per_week: r.sessions_per_week.map(|n| n.max(0) as u32),
                minutes_per_session: r.minutes_per_session.map(|n| n.max(0) as u32),
                exercises: serde_json::from_str(&r.exercises_json).unwrap_or_default(),
                source: r.source,
                active: r.active,
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Exercise log
    // -----------------------------------------------------------------------

    /// Record a completed exercise session.
    #[allow(clippy::too_many_arguments)]
    pub async fn log_exercise_session(
        &self,
        plan_id: Option<&str>,
        session_type: &str,
        description: &str,
        duration_min: u32,
        rpe_1_10: Option<u8>,
        completed_at: Option<DateTime<Utc>>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<ExerciseSession> {
        let session_type = normalize_non_empty(session_type).context("session_type required")?;
        let description = normalize_non_empty(description).context("description required")?;
        if duration_min == 0 {
            anyhow::bail!("duration_min must be > 0");
        }
        if let Some(r) = rpe_1_10 {
            if !(1..=10).contains(&r) {
                anyhow::bail!("rpe_1_10 must be in 1..=10");
            }
        }
        let plan_id = plan_id.and_then(normalize_non_empty);
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let completed = completed_at.unwrap_or_else(Utc::now);
        let completed_rfc = completed.to_rfc3339();
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let session_id = format!("esess-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let session_id_clone = session_id.clone();
        let plan_id_clone = plan_id.clone();
        let session_type_clone = session_type.clone();
        let description_clone = description.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO exercise_log
                 (session_id, plan_id, session_type, description, duration_min,
                  rpe_1_10, notes_nonce_b64, notes_ciphertext_b64, completed_at,
                  source_entry_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    session_id_clone,
                    plan_id_clone,
                    session_type_clone,
                    description_clone,
                    duration_min as i32,
                    rpe_1_10.map(|r| r as i32),
                    notes_nonce,
                    notes_cipher,
                    completed_rfc,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(ExerciseSession {
            session_id,
            plan_id,
            session_type,
            description,
            duration_min,
            rpe_1_10,
            notes: notes_owned,
            completed_at: completed,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
        })
    }

    /// Recent exercise sessions, newest first.
    pub async fn list_exercise_sessions(&self, limit: usize) -> Result<Vec<ExerciseSession>> {
        let db_path = self.db_path.clone();
        let limit = limit.clamp(1, 1000) as i64;
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT session_id, plan_id, session_type, description,
                        duration_min, rpe_1_10, notes_nonce_b64, notes_ciphertext_b64,
                        completed_at, source_entry_id, created_at
                 FROM exercise_log
                 ORDER BY completed_at DESC
                 LIMIT ?1",
            )?;
            let raws: Vec<ExerciseSessionRaw> = stmt
                .query_map(params![limit], |row| {
                    Ok(ExerciseSessionRaw {
                        session_id: row.get(0)?,
                        plan_id: row.get(1)?,
                        session_type: row.get(2)?,
                        description: row.get(3)?,
                        duration_min: row.get(4)?,
                        rpe_1_10: row.get(5)?,
                        notes_nonce_b64: row.get(6)?,
                        notes_ciphertext_b64: row.get(7)?,
                        completed_at: row.get(8)?,
                        source_entry_id: row.get(9)?,
                        created_at: row.get(10)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| ExerciseSession {
                session_id: r.session_id,
                plan_id: r.plan_id,
                session_type: r.session_type,
                description: r.description,
                duration_min: r.duration_min.max(0) as u32,
                rpe_1_10: r.rpe_1_10.map(|n| n.clamp(0, 10) as u8),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                completed_at: parse_utc(&r.completed_at),
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Exercise summary aggregator
    // -----------------------------------------------------------------------

    /// Aggregate exercise snapshot for the user.
    ///
    /// Combines: full active inventory, all active plans, the last
    /// `recent_sessions_limit` sessions, and the count + total
    /// duration over the last 7 / 30 days. The day windows are
    /// computed against `now_utc` so the caller does not have to
    /// thread a clock through the test.
    pub async fn get_exercise_summary(
        &self,
        recent_sessions_limit: usize,
    ) -> Result<ExerciseSummary> {
        let inventory = self.list_exercise_inventory(true).await?;
        let active_plans = self.list_exercise_plans(true).await?;
        let recent_sessions = self.list_exercise_sessions(recent_sessions_limit).await?;

        let now_utc = Utc::now();
        let cutoff_7 = now_utc - chrono::Duration::days(7);
        let cutoff_30 = now_utc - chrono::Duration::days(30);

        // Pull the rolling-window counts via SQL so we don't bring
        // every session into RAM just to count.
        let db_path = self.db_path.clone();
        let cutoff_7_str = cutoff_7.to_rfc3339();
        let cutoff_30_str = cutoff_30.to_rfc3339();
        let (sessions_7, sessions_30, minutes_30) =
            tokio::task::spawn_blocking(move || -> Result<(u32, u32, u32)> {
                let db = Self::open_db(&db_path)?;
                let s7: i64 = db.query_row(
                    "SELECT COUNT(*) FROM exercise_log WHERE completed_at >= ?1",
                    params![cutoff_7_str],
                    |r| r.get(0),
                )?;
                let s30: i64 = db.query_row(
                    "SELECT COUNT(*) FROM exercise_log WHERE completed_at >= ?1",
                    params![cutoff_30_str],
                    |r| r.get(0),
                )?;
                let m30: i64 = db
                    .query_row(
                        "SELECT COALESCE(SUM(duration_min), 0)
                         FROM exercise_log
                         WHERE completed_at >= ?1",
                        params![cutoff_30_str],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                Ok((s7.max(0) as u32, s30.max(0) as u32, m30.max(0) as u32))
            })
            .await??;

        Ok(ExerciseSummary {
            inventory,
            active_plans,
            recent_sessions,
            sessions_last_7_days: sessions_7,
            sessions_last_30_days: sessions_30,
            total_minutes_last_30_days: minutes_30,
            generated_at: now_utc,
        })
    }
}

// -- Private raw row types for BI.5 -------------------------------------------

struct ExerciseInventoryRaw {
    item_id: String,
    item_name: String,
    item_category: String,
    quantity: i32,
    notes: Option<String>,
    active: bool,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct ExercisePlanRaw {
    plan_id: String,
    name: String,
    description: Option<String>,
    goal: Option<String>,
    sessions_per_week: Option<i32>,
    minutes_per_session: Option<i32>,
    exercises_json: String,
    source: Option<String>,
    active: bool,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct ExerciseSessionRaw {
    session_id: String,
    plan_id: Option<String>,
    session_type: String,
    description: String,
    duration_min: i32,
    rpe_1_10: Option<i32>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    completed_at: String,
    source_entry_id: Option<String>,
    created_at: String,
}

// ============================================================================
// Fase BI.3 sprint 1 — Nutricion (Vida Plena)
// ============================================================================

/// One nutrition preference / restriction the user has.
///
/// Examples: alergia a los mariscos (severe), intolerancia a la
/// lactosa, dieta mediterranea, le encanta el aguacate, odia el
/// cilantro, meta de bajar 5kg para junio.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NutritionPreference {
    pub pref_id: String,
    /// `allergy`, `intolerance`, `diet`, `like`, `dislike`, `goal`.
    pub pref_type: String,
    pub label: String,
    /// Solo relevante para alergias: `mild`, `moderate`, `severe`,
    /// `life_threatening`.
    pub severity: Option<String>,
    pub notes: String,
    pub active: bool,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// One meal/snack/drink/craving registered by the user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NutritionLogEntry {
    pub log_id: String,
    /// `breakfast`, `lunch`, `dinner`, `snack`, `drink`, `craving`.
    pub meal_type: String,
    /// Free text or vision-LLM result. The narrative; not the macros.
    pub description: String,
    /// FK opcional a `health_attachments` para la foto.
    pub photo_attachment_id: Option<String>,
    /// FK opcional a `health_attachments` para la nota de voz.
    pub voice_attachment_id: Option<String>,
    pub macros_kcal: Option<f64>,
    pub macros_protein_g: Option<f64>,
    pub macros_carbs_g: Option<f64>,
    pub macros_fat_g: Option<f64>,
    pub consumed_at: DateTime<Utc>,
    /// Encrypted free-text notes (sentir, despues de comer, etc.).
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// One ingredient inside a recipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecipeIngredient {
    pub name: String,
    pub amount: f64,
    pub unit: String,
    pub notes: Option<String>,
}

/// A saved recipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recipe {
    pub recipe_id: String,
    pub name: String,
    pub description: Option<String>,
    pub ingredients: Vec<RecipeIngredient>,
    pub steps: Vec<String>,
    pub prep_time_min: Option<u32>,
    pub cook_time_min: Option<u32>,
    pub servings: Option<u32>,
    pub tags: Vec<String>,
    pub source: Option<String>,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// A nutrition plan (defined by Axi or by a real nutrionist).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NutritionPlan {
    pub plan_id: String,
    pub name: String,
    pub description: Option<String>,
    pub goal: Option<String>,
    pub duration_days: Option<u32>,
    pub daily_kcal_target: Option<f64>,
    pub daily_protein_g_target: Option<f64>,
    pub daily_carbs_g_target: Option<f64>,
    pub daily_fat_g_target: Option<f64>,
    pub source: Option<String>,
    pub active: bool,
    pub started_at: Option<DateTime<Utc>>,
    pub notes: String,
    pub source_entry_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Aggregate snapshot returned by `get_nutrition_summary`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NutritionSummary {
    pub preferences: Vec<NutritionPreference>,
    pub active_plan: Option<NutritionPlan>,
    pub recent_meals: Vec<NutritionLogEntry>,
    /// Sumas rolling de los ultimos 7 dias.
    pub kcal_last_7_days: f64,
    pub protein_g_last_7_days: f64,
    pub carbs_g_last_7_days: f64,
    pub fat_g_last_7_days: f64,
    pub meals_last_7_days: u32,
    pub generated_at: DateTime<Utc>,
}

impl MemoryPlaneManager {
    // -----------------------------------------------------------------------
    // Nutrition preferences
    // -----------------------------------------------------------------------

    pub async fn add_nutrition_preference(
        &self,
        pref_type: &str,
        label: &str,
        severity: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<NutritionPreference> {
        let pref_type = normalize_non_empty(pref_type).context("pref_type required")?;
        let label = normalize_non_empty(label).context("label required")?;
        let severity = severity
            .and_then(normalize_non_empty)
            .map(|s| s.to_lowercase());
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let pref_id = format!("npref-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let pref_id_clone = pref_id.clone();
        let pref_type_clone = pref_type.clone();
        let label_clone = label.clone();
        let severity_clone = severity.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO nutrition_preferences
                 (pref_id, pref_type, label, severity, notes_nonce_b64,
                  notes_ciphertext_b64, active, source_entry_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?8, ?8)",
                params![
                    pref_id_clone,
                    pref_type_clone,
                    label_clone,
                    severity_clone,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(NutritionPreference {
            pref_id,
            pref_type,
            label,
            severity,
            notes: notes_owned,
            active: true,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    /// Mark a preference inactive (the user grew out of an allergy,
    /// gave up a diet, etc.). Allergies are particularly delicate —
    /// the caller should confirm with the user before deactivating
    /// a `severity = severe` row.
    pub async fn deactivate_nutrition_preference(&self, pref_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = pref_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE nutrition_preferences
                 SET active = 0, updated_at = ?1
                 WHERE pref_id = ?2 AND active = 1",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    /// List nutrition preferences. `pref_type` filter is optional;
    /// `active_only` defaults to true at the call site.
    pub async fn list_nutrition_preferences(
        &self,
        pref_type: Option<&str>,
        active_only: bool,
    ) -> Result<Vec<NutritionPreference>> {
        let db_path = self.db_path.clone();
        let filter = pref_type.map(|s| s.to_string());
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT pref_id, pref_type, label, severity, notes_nonce_b64,
                        notes_ciphertext_b64, active, source_entry_id,
                        created_at, updated_at
                 FROM nutrition_preferences",
            );
            let mut conditions: Vec<&str> = Vec::new();
            if active_only {
                conditions.push("active = 1");
            }
            if filter.is_some() {
                conditions.push("pref_type = ?1");
            }
            if !conditions.is_empty() {
                sql.push_str(" WHERE ");
                sql.push_str(&conditions.join(" AND "));
            }
            sql.push_str(" ORDER BY created_at DESC");

            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<NutritionPreferenceRaw> {
                Ok(NutritionPreferenceRaw {
                    pref_id: row.get(0)?,
                    pref_type: row.get(1)?,
                    label: row.get(2)?,
                    severity: row.get(3)?,
                    notes_nonce_b64: row.get(4)?,
                    notes_ciphertext_b64: row.get(5)?,
                    active: row.get::<_, i32>(6)? != 0,
                    source_entry_id: row.get(7)?,
                    created_at: row.get(8)?,
                    updated_at: row.get(9)?,
                })
            };
            let raws: Vec<NutritionPreferenceRaw> = if let Some(f) = filter {
                stmt.query_map(params![f], map_row)?.flatten().collect()
            } else {
                stmt.query_map([], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| NutritionPreference {
                pref_id: r.pref_id,
                pref_type: r.pref_type,
                label: r.label,
                severity: r.severity,
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                active: r.active,
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Nutrition log
    // -----------------------------------------------------------------------

    /// Record a meal/snack/drink. Most fields are optional — even
    /// `description` allows free narrative; macros and attachments
    /// are populated only when the user (or vision pipeline) provides
    /// them.
    #[allow(clippy::too_many_arguments)]
    pub async fn log_nutrition_meal(
        &self,
        meal_type: &str,
        description: &str,
        macros_kcal: Option<f64>,
        macros_protein_g: Option<f64>,
        macros_carbs_g: Option<f64>,
        macros_fat_g: Option<f64>,
        photo_attachment_id: Option<&str>,
        voice_attachment_id: Option<&str>,
        consumed_at: Option<DateTime<Utc>>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<NutritionLogEntry> {
        let meal_type = normalize_non_empty(meal_type).context("meal_type required")?;
        let description = normalize_non_empty(description).context("description required")?;
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        // Validate: macros, when present, must be non-negative.
        for (label, v) in [
            ("macros_kcal", macros_kcal),
            ("macros_protein_g", macros_protein_g),
            ("macros_carbs_g", macros_carbs_g),
            ("macros_fat_g", macros_fat_g),
        ] {
            if let Some(value) = v {
                if value < 0.0 || !value.is_finite() {
                    anyhow::bail!("{} must be a non-negative finite number", label);
                }
            }
        }

        let consumed = consumed_at.unwrap_or_else(Utc::now);
        let consumed_rfc = consumed.to_rfc3339();
        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let log_id = format!("nlog-{}", Uuid::new_v4());
        let photo_owned = photo_attachment_id.map(|s| s.to_string());
        let voice_owned = voice_attachment_id.map(|s| s.to_string());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let log_id_clone = log_id.clone();
        let meal_type_clone = meal_type.clone();
        let description_clone = description.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO nutrition_log
                 (log_id, meal_type, description, photo_attachment_id,
                  voice_attachment_id, macros_kcal, macros_protein_g,
                  macros_carbs_g, macros_fat_g, consumed_at, notes_nonce_b64,
                  notes_ciphertext_b64, source_entry_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    log_id_clone,
                    meal_type_clone,
                    description_clone,
                    photo_owned,
                    voice_owned,
                    macros_kcal,
                    macros_protein_g,
                    macros_carbs_g,
                    macros_fat_g,
                    consumed_rfc,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(NutritionLogEntry {
            log_id,
            meal_type,
            description,
            photo_attachment_id: photo_attachment_id.map(|s| s.to_string()),
            voice_attachment_id: voice_attachment_id.map(|s| s.to_string()),
            macros_kcal,
            macros_protein_g,
            macros_carbs_g,
            macros_fat_g,
            consumed_at: consumed,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
        })
    }

    /// List the most recent N nutrition log entries (newest first),
    /// optionally filtered by meal_type.
    pub async fn list_nutrition_log(
        &self,
        meal_type: Option<&str>,
        limit: usize,
    ) -> Result<Vec<NutritionLogEntry>> {
        let db_path = self.db_path.clone();
        let filter = meal_type.map(|s| s.to_string());
        let limit = limit.clamp(1, 1000) as i64;
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut sql = String::from(
                "SELECT log_id, meal_type, description, photo_attachment_id,
                        voice_attachment_id, macros_kcal, macros_protein_g,
                        macros_carbs_g, macros_fat_g, consumed_at, notes_nonce_b64,
                        notes_ciphertext_b64, source_entry_id, created_at
                 FROM nutrition_log",
            );
            if filter.is_some() {
                sql.push_str(" WHERE meal_type = ?1 ORDER BY consumed_at DESC LIMIT ?2");
            } else {
                sql.push_str(" ORDER BY consumed_at DESC LIMIT ?1");
            }
            let mut stmt = db.prepare(&sql)?;
            let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<NutritionLogRaw> {
                Ok(NutritionLogRaw {
                    log_id: row.get(0)?,
                    meal_type: row.get(1)?,
                    description: row.get(2)?,
                    photo_attachment_id: row.get(3)?,
                    voice_attachment_id: row.get(4)?,
                    macros_kcal: row.get(5)?,
                    macros_protein_g: row.get(6)?,
                    macros_carbs_g: row.get(7)?,
                    macros_fat_g: row.get(8)?,
                    consumed_at: row.get(9)?,
                    notes_nonce_b64: row.get(10)?,
                    notes_ciphertext_b64: row.get(11)?,
                    source_entry_id: row.get(12)?,
                    created_at: row.get(13)?,
                })
            };
            let raws: Vec<NutritionLogRaw> = if let Some(f) = filter {
                stmt.query_map(params![f, limit], map_row)?
                    .flatten()
                    .collect()
            } else {
                stmt.query_map(params![limit], map_row)?.flatten().collect()
            };
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| NutritionLogEntry {
                log_id: r.log_id,
                meal_type: r.meal_type,
                description: r.description,
                photo_attachment_id: r.photo_attachment_id,
                voice_attachment_id: r.voice_attachment_id,
                macros_kcal: r.macros_kcal,
                macros_protein_g: r.macros_protein_g,
                macros_carbs_g: r.macros_carbs_g,
                macros_fat_g: r.macros_fat_g,
                consumed_at: parse_utc(&r.consumed_at),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Nutrition recipes
    // -----------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub async fn add_recipe(
        &self,
        name: &str,
        description: Option<&str>,
        ingredients: Vec<RecipeIngredient>,
        steps: Vec<String>,
        prep_time_min: Option<u32>,
        cook_time_min: Option<u32>,
        servings: Option<u32>,
        tags: Vec<String>,
        source: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<Recipe> {
        let name = normalize_non_empty(name).context("name required")?;
        let description = description.and_then(normalize_non_empty);
        if ingredients.is_empty() {
            anyhow::bail!("recipe must have at least one ingredient");
        }
        if steps.is_empty() {
            anyhow::bail!("recipe must have at least one step");
        }
        let source = source.and_then(normalize_non_empty);
        let ingredients_json = serde_json::to_string(&ingredients)
            .context("failed to serialise recipe ingredients")?;
        let steps_json =
            serde_json::to_string(&steps).context("failed to serialise recipe steps")?;
        let tags_json =
            serde_json::to_string(&tags).context("failed to serialise recipe tags")?;
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let recipe_id = format!("nrec-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let recipe_id_clone = recipe_id.clone();
        let name_clone = name.clone();
        let description_clone = description.clone();
        let source_clone = source.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO nutrition_recipes
                 (recipe_id, name, description, ingredients_json, steps_json,
                  prep_time_min, cook_time_min, servings, tags, source,
                  notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14)",
                params![
                    recipe_id_clone,
                    name_clone,
                    description_clone,
                    ingredients_json,
                    steps_json,
                    prep_time_min.map(|n| n as i32),
                    cook_time_min.map(|n| n as i32),
                    servings.map(|n| n as i32),
                    tags_json,
                    source_clone,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                    now_rfc,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(Recipe {
            recipe_id,
            name,
            description,
            ingredients,
            steps,
            prep_time_min,
            cook_time_min,
            servings,
            tags,
            source,
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    pub async fn list_recipes(&self, tag: Option<&str>) -> Result<Vec<Recipe>> {
        let db_path = self.db_path.clone();
        let tag_filter = tag.map(|s| s.to_string());
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT recipe_id, name, description, ingredients_json, steps_json,
                        prep_time_min, cook_time_min, servings, tags, source,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM nutrition_recipes
                 ORDER BY updated_at DESC",
            )?;
            let raws: Vec<RecipeRaw> = stmt
                .query_map([], |row| {
                    Ok(RecipeRaw {
                        recipe_id: row.get(0)?,
                        name: row.get(1)?,
                        description: row.get(2)?,
                        ingredients_json: row.get(3)?,
                        steps_json: row.get(4)?,
                        prep_time_min: row.get(5)?,
                        cook_time_min: row.get(6)?,
                        servings: row.get(7)?,
                        tags_json: row.get(8)?,
                        source: row.get(9)?,
                        notes_nonce_b64: row.get(10)?,
                        notes_ciphertext_b64: row.get(11)?,
                        source_entry_id: row.get(12)?,
                        created_at: row.get(13)?,
                        updated_at: row.get(14)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        // Convert + apply tag filter in Rust because the tags are
        // stored as JSON. Cheap because we already pulled the rows.
        let recipes: Vec<Recipe> = raws
            .into_iter()
            .map(|r| Recipe {
                recipe_id: r.recipe_id,
                name: r.name,
                description: r.description,
                ingredients: serde_json::from_str(&r.ingredients_json).unwrap_or_default(),
                steps: serde_json::from_str(&r.steps_json).unwrap_or_default(),
                prep_time_min: r.prep_time_min.map(|n| n.max(0) as u32),
                cook_time_min: r.cook_time_min.map(|n| n.max(0) as u32),
                servings: r.servings.map(|n| n.max(0) as u32),
                tags: serde_json::from_str(&r.tags_json).unwrap_or_default(),
                source: r.source,
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect();

        Ok(match tag_filter {
            Some(t) => {
                let needle = t.to_lowercase();
                recipes
                    .into_iter()
                    .filter(|r| {
                        r.tags
                            .iter()
                            .any(|x| x.eq_ignore_ascii_case(needle.as_str()))
                    })
                    .collect()
            }
            None => recipes,
        })
    }

    pub async fn delete_recipe(&self, recipe_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = recipe_id.to_string();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "DELETE FROM nutrition_recipes WHERE recipe_id = ?1",
                params![id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    // -----------------------------------------------------------------------
    // Nutrition plans
    // -----------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub async fn add_nutrition_plan(
        &self,
        name: &str,
        description: Option<&str>,
        goal: Option<&str>,
        duration_days: Option<u32>,
        daily_kcal_target: Option<f64>,
        daily_protein_g_target: Option<f64>,
        daily_carbs_g_target: Option<f64>,
        daily_fat_g_target: Option<f64>,
        source: Option<&str>,
        notes: &str,
        source_entry_id: Option<&str>,
    ) -> Result<NutritionPlan> {
        let name = normalize_non_empty(name).context("name required")?;
        let description = description.and_then(normalize_non_empty);
        let goal = goal.and_then(normalize_non_empty);
        let source = source.and_then(normalize_non_empty);
        for (label, v) in [
            ("daily_kcal_target", daily_kcal_target),
            ("daily_protein_g_target", daily_protein_g_target),
            ("daily_carbs_g_target", daily_carbs_g_target),
            ("daily_fat_g_target", daily_fat_g_target),
        ] {
            if let Some(value) = v {
                if value < 0.0 || !value.is_finite() {
                    anyhow::bail!("{} must be non-negative finite", label);
                }
            }
        }
        let notes_owned = notes.trim().to_string();
        let (notes_nonce, notes_cipher) = if notes_owned.is_empty() {
            (None, None)
        } else {
            let (n, c, _) = encrypt_content(&notes_owned)?;
            (Some(n), Some(c))
        };

        let now = Utc::now();
        let now_rfc = now.to_rfc3339();
        let plan_id = format!("nplan-{}", Uuid::new_v4());
        let source_owned = source_entry_id.map(|s| s.to_string());

        let db_path = self.db_path.clone();
        let plan_id_clone = plan_id.clone();
        let name_clone = name.clone();
        let description_clone = description.clone();
        let goal_clone = goal.clone();
        let source_clone = source.clone();
        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT INTO nutrition_plans
                 (plan_id, name, description, goal, duration_days,
                  daily_kcal_target, daily_protein_g_target, daily_carbs_g_target,
                  daily_fat_g_target, source, active, started_at,
                  notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, ?11, ?12, ?13, ?14, ?11, ?11)",
                params![
                    plan_id_clone,
                    name_clone,
                    description_clone,
                    goal_clone,
                    duration_days.map(|n| n as i32),
                    daily_kcal_target,
                    daily_protein_g_target,
                    daily_carbs_g_target,
                    daily_fat_g_target,
                    source_clone,
                    now_rfc,
                    notes_nonce,
                    notes_cipher,
                    source_owned,
                ],
            )?;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(NutritionPlan {
            plan_id,
            name,
            description,
            goal,
            duration_days,
            daily_kcal_target,
            daily_protein_g_target,
            daily_carbs_g_target,
            daily_fat_g_target,
            source,
            active: true,
            started_at: Some(now),
            notes: notes_owned,
            source_entry_id: source_entry_id.map(|s| s.to_string()),
            created_at: now,
            updated_at: now,
        })
    }

    pub async fn deactivate_nutrition_plan(&self, plan_id: &str) -> Result<bool> {
        let db_path = self.db_path.clone();
        let id = plan_id.to_string();
        let now = Utc::now().to_rfc3339();
        let n = tokio::task::spawn_blocking(move || -> Result<usize> {
            let db = Self::open_db(&db_path)?;
            Ok(db.execute(
                "UPDATE nutrition_plans SET active = 0, updated_at = ?1
                 WHERE plan_id = ?2 AND active = 1",
                params![now, id],
            )?)
        })
        .await??;
        Ok(n > 0)
    }

    pub async fn list_nutrition_plans(&self, active_only: bool) -> Result<Vec<NutritionPlan>> {
        let db_path = self.db_path.clone();
        let raws = tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let sql = if active_only {
                "SELECT plan_id, name, description, goal, duration_days,
                        daily_kcal_target, daily_protein_g_target, daily_carbs_g_target,
                        daily_fat_g_target, source, active, started_at,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM nutrition_plans WHERE active = 1
                 ORDER BY created_at DESC"
            } else {
                "SELECT plan_id, name, description, goal, duration_days,
                        daily_kcal_target, daily_protein_g_target, daily_carbs_g_target,
                        daily_fat_g_target, source, active, started_at,
                        notes_nonce_b64, notes_ciphertext_b64, source_entry_id,
                        created_at, updated_at
                 FROM nutrition_plans
                 ORDER BY created_at DESC"
            };
            let mut stmt = db.prepare(sql)?;
            let raws: Vec<NutritionPlanRaw> = stmt
                .query_map([], |row| {
                    Ok(NutritionPlanRaw {
                        plan_id: row.get(0)?,
                        name: row.get(1)?,
                        description: row.get(2)?,
                        goal: row.get(3)?,
                        duration_days: row.get(4)?,
                        daily_kcal_target: row.get(5)?,
                        daily_protein_g_target: row.get(6)?,
                        daily_carbs_g_target: row.get(7)?,
                        daily_fat_g_target: row.get(8)?,
                        source: row.get(9)?,
                        active: row.get::<_, i32>(10)? != 0,
                        started_at: row.get(11)?,
                        notes_nonce_b64: row.get(12)?,
                        notes_ciphertext_b64: row.get(13)?,
                        source_entry_id: row.get(14)?,
                        created_at: row.get(15)?,
                        updated_at: row.get(16)?,
                    })
                })?
                .flatten()
                .collect();
            Ok::<_, anyhow::Error>(raws)
        })
        .await??;

        Ok(raws
            .into_iter()
            .map(|r| NutritionPlan {
                plan_id: r.plan_id,
                name: r.name,
                description: r.description,
                goal: r.goal,
                duration_days: r.duration_days.map(|n| n.max(0) as u32),
                daily_kcal_target: r.daily_kcal_target,
                daily_protein_g_target: r.daily_protein_g_target,
                daily_carbs_g_target: r.daily_carbs_g_target,
                daily_fat_g_target: r.daily_fat_g_target,
                source: r.source,
                active: r.active,
                started_at: r.started_at.as_deref().map(parse_utc),
                notes: match (r.notes_nonce_b64, r.notes_ciphertext_b64) {
                    (Some(n), Some(c)) => decrypt_to_string(&n, &c).unwrap_or_default(),
                    _ => String::new(),
                },
                source_entry_id: r.source_entry_id,
                created_at: parse_utc(&r.created_at),
                updated_at: parse_utc(&r.updated_at),
            })
            .collect())
    }

    // -----------------------------------------------------------------------
    // Nutrition summary aggregator
    // -----------------------------------------------------------------------

    /// Aggregate nutrition snapshot. Combines: all active preferences,
    /// the most-recent active plan (if any), the last
    /// `recent_meals_limit` meals, and rolling 7-day macro totals.
    pub async fn get_nutrition_summary(
        &self,
        recent_meals_limit: usize,
    ) -> Result<NutritionSummary> {
        let preferences = self.list_nutrition_preferences(None, true).await?;
        let active_plans = self.list_nutrition_plans(true).await?;
        let active_plan = active_plans.into_iter().next();
        let recent_meals = self.list_nutrition_log(None, recent_meals_limit).await?;

        // Pull rolling 7-day macros via a single SQL aggregation.
        let now_utc = Utc::now();
        let cutoff_7 = (now_utc - chrono::Duration::days(7)).to_rfc3339();
        let db_path = self.db_path.clone();
        let totals: (f64, f64, f64, f64, u32) =
            tokio::task::spawn_blocking(move || -> Result<(f64, f64, f64, f64, u32)> {
                let db = Self::open_db(&db_path)?;
                let row: (Option<f64>, Option<f64>, Option<f64>, Option<f64>, i64) = db
                    .query_row(
                        "SELECT
                            SUM(macros_kcal),
                            SUM(macros_protein_g),
                            SUM(macros_carbs_g),
                            SUM(macros_fat_g),
                            COUNT(*)
                         FROM nutrition_log
                         WHERE consumed_at >= ?1",
                        params![cutoff_7],
                        |r| {
                            Ok((
                                r.get::<_, Option<f64>>(0)?,
                                r.get::<_, Option<f64>>(1)?,
                                r.get::<_, Option<f64>>(2)?,
                                r.get::<_, Option<f64>>(3)?,
                                r.get::<_, i64>(4)?,
                            ))
                        },
                    )
                    .unwrap_or((None, None, None, None, 0));
                Ok((
                    row.0.unwrap_or(0.0),
                    row.1.unwrap_or(0.0),
                    row.2.unwrap_or(0.0),
                    row.3.unwrap_or(0.0),
                    row.4.max(0) as u32,
                ))
            })
            .await??;

        Ok(NutritionSummary {
            preferences,
            active_plan,
            recent_meals,
            kcal_last_7_days: totals.0,
            protein_g_last_7_days: totals.1,
            carbs_g_last_7_days: totals.2,
            fat_g_last_7_days: totals.3,
            meals_last_7_days: totals.4,
            generated_at: now_utc,
        })
    }
}

// -- Private raw row types for BI.3 -------------------------------------------

struct NutritionPreferenceRaw {
    pref_id: String,
    pref_type: String,
    label: String,
    severity: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    active: bool,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct NutritionLogRaw {
    log_id: String,
    meal_type: String,
    description: String,
    photo_attachment_id: Option<String>,
    voice_attachment_id: Option<String>,
    macros_kcal: Option<f64>,
    macros_protein_g: Option<f64>,
    macros_carbs_g: Option<f64>,
    macros_fat_g: Option<f64>,
    consumed_at: String,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
}

struct RecipeRaw {
    recipe_id: String,
    name: String,
    description: Option<String>,
    ingredients_json: String,
    steps_json: String,
    prep_time_min: Option<i32>,
    cook_time_min: Option<i32>,
    servings: Option<i32>,
    tags_json: String,
    source: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

struct NutritionPlanRaw {
    plan_id: String,
    name: String,
    description: Option<String>,
    goal: Option<String>,
    duration_days: Option<i32>,
    daily_kcal_target: Option<f64>,
    daily_protein_g_target: Option<f64>,
    daily_carbs_g_target: Option<f64>,
    daily_fat_g_target: Option<f64>,
    source: Option<String>,
    active: bool,
    started_at: Option<String>,
    notes_nonce_b64: Option<String>,
    notes_ciphertext_b64: Option<String>,
    source_entry_id: Option<String>,
    created_at: String,
    updated_at: String,
}

fn parse_utc(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now())
}

fn normalize_non_empty(input: &str) -> Option<String> {
    let value = input.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// True if the entry `kind` belongs to the Fase BI "Vida Plena" pillar.
///
/// Wellness kinds skip decay, GC, dedup, and cluster summarisation —
/// they are auto-marked permanent at insert time so the user does not
/// have to remember to flag them. The contract is the kind namespace:
/// any kind starting with `health_`, `wellness_`, `mental_`,
/// `nutrition_`, `exercise_`, `sleep_`, `relationship_`, `family_`,
/// `child_`, `spiritual_`, `financial_`, `sexual_`, or `community_` is
/// considered wellness data and gets the protection.
///
/// This list is the single source of truth for the auto-permanent
/// behaviour. Add a new prefix here when introducing a new wellness
/// sub-fase (BI.X) so its data is automatically protected.
pub fn is_wellness_kind(kind: &str) -> bool {
    const WELLNESS_PREFIXES: &[&str] = &[
        "health_",
        "wellness_",
        "mental_",
        "nutrition_",
        "exercise_",
        "sleep_",
        "relationship_",
        "family_",
        "child_",
        "spiritual_",
        "financial_",
        "sexual_",
        "community_",
    ];
    let lower = kind.trim().to_lowercase();
    WELLNESS_PREFIXES.iter().any(|p| lower.starts_with(p))
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
        "lunes",
        "martes",
        "miercoles",
        "miércoles",
        "jueves",
        "viernes",
        "sabado",
        "sábado",
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
    async fn test_apply_decay_archives_low_importance_old() {
        let dir = temp_dir("memory-plane-decay-archive");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Low importance + > 90 days old => archived by the <10/90d rule.
        // BI.1: this used to DELETE the entry; now it sets archived=1.
        let entry = mgr
            .add_entry("note", "user", &[], None, 5, "Old trivial entry.")
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 100);

        let report = mgr.apply_decay().await.unwrap();
        // `deleted` is the field name (kept for back-compat) but the
        // semantics are now "newly archived this pass".
        assert!(report.deleted >= 1, "Should archive at least one entry");

        // Live view must hide it.
        let entries = mgr.list_entries(50, None, None).await.unwrap();
        assert!(
            entries.iter().all(|e| e.entry_id != entry.entry_id),
            "Stale low-importance entry should drop out of live list"
        );

        // But it must STILL be on disk with archived=1 (the BI.1 contract).
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let archived: i32 = db
            .query_row(
                "SELECT archived FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(archived, 1, "Entry must be flagged archived, not deleted");

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
        assert_eq!(moved, 2, "Both targeted entries should be archived");

        // BI.1 update: archive is now a soft flag, not a move. Originals
        // must be GONE from the default `list_entries` view (which
        // filters archived) but STILL PRESENT in the underlying table
        // with `archived = 1`.
        let live_entries = mgr.list_entries(50, None, None).await.unwrap();
        let live_ids: Vec<&str> = live_entries.iter().map(|e| e.entry_id.as_str()).collect();
        assert!(!live_ids.contains(&e1.entry_id.as_str()));
        assert!(!live_ids.contains(&e2.entry_id.as_str()));
        // Unrelated entry must survive in the live view.
        assert!(live_ids.contains(&e3.entry_id.as_str()));

        // The archived rows still live in memory_entries with the flag set.
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let archived_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_entries
                 WHERE entry_id IN (?1, ?2) AND archived = 1",
                params![e1.entry_id, e2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(archived_count, 2, "Both entries should be flagged archived=1");

        // Embeddings are PRESERVED on archive so search_archived can find
        // them via semantic recall (the BI.1 "never lose anything" rule).
        let embed_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_embeddings WHERE entry_id IN (?1, ?2)",
                params![e1.entry_id, e2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(embed_count, 2, "Embeddings must be preserved on archive");

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

    // ---- BI.1: Sprint 1 — "nunca perder nada" -------------------------------

    #[test]
    fn test_is_wellness_kind_recognises_pillar_prefixes() {
        // Positive cases — every wellness pillar prefix.
        assert!(is_wellness_kind("health_event"));
        assert!(is_wellness_kind("health_medication"));
        assert!(is_wellness_kind("wellness_check_in"));
        assert!(is_wellness_kind("mental_journal"));
        assert!(is_wellness_kind("nutrition_log"));
        assert!(is_wellness_kind("exercise_session"));
        assert!(is_wellness_kind("sleep_log"));
        assert!(is_wellness_kind("relationship_event"));
        assert!(is_wellness_kind("family_milestone"));
        assert!(is_wellness_kind("child_milestone"));
        assert!(is_wellness_kind("spiritual_practice"));
        assert!(is_wellness_kind("financial_expense"));
        assert!(is_wellness_kind("sexual_health"));
        assert!(is_wellness_kind("community_activity"));
        // Case-insensitive + leading whitespace tolerant.
        assert!(is_wellness_kind("HEALTH_event"));
        assert!(is_wellness_kind("  mental_log  "));

        // Negative cases — non-wellness kinds must NOT auto-permanent.
        assert!(!is_wellness_kind("note"));
        assert!(!is_wellness_kind("decision"));
        assert!(!is_wellness_kind("bugfix"));
        assert!(!is_wellness_kind("cluster_summary"));
        assert!(!is_wellness_kind("preference"));
        assert!(!is_wellness_kind(""));
    }

    #[tokio::test]
    async fn test_health_kind_auto_permanent() {
        let dir = temp_dir("memory-plane-health-permanent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Health entry — should be auto-permanent.
        let health = mgr
            .add_entry(
                "health_event",
                "user",
                &["gripa".into()],
                None,
                40,
                "Hoy me siento con tos y dolor de garganta",
            )
            .await
            .unwrap();
        // Plain note — should NOT be permanent.
        let note = mgr
            .add_entry("note", "user", &[], None, 40, "una nota cualquiera")
            .await
            .unwrap();

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let health_perm: i32 = db
            .query_row(
                "SELECT permanent FROM memory_entries WHERE entry_id = ?1",
                params![health.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(health_perm, 1, "health_event must be auto-permanent");

        let note_perm: i32 = db
            .query_row(
                "SELECT permanent FROM memory_entries WHERE entry_id = ?1",
                params![note.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(note_perm, 0, "plain note must NOT be auto-permanent");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_health_entries_survive_decay_indefinitely() {
        let dir = temp_dir("memory-plane-health-survives-decay");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Low importance + 365 days old — would normally hit BOTH GC
        // thresholds. But because it's a health_ kind, it auto-marks
        // permanent and skips every decay/GC stage.
        let entry = mgr
            .add_entry(
                "health_vital",
                "user",
                &[],
                None,
                5,
                "presion 130/85 hace un año",
            )
            .await
            .unwrap();
        backdate(&dir, &entry.entry_id, 365);

        let _ = mgr.apply_decay().await.unwrap();

        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let row: (i32, i32, i32) = db
            .query_row(
                "SELECT importance, COALESCE(archived,0), COALESCE(permanent,0)
                 FROM memory_entries WHERE entry_id = ?1",
                params![entry.entry_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(row.0, 5, "importance must NOT decay");
        assert_eq!(row.1, 0, "must NOT be archived");
        assert_eq!(row.2, 1, "must remain permanent");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_dedup_skips_health_pairs() {
        let dir = temp_dir("memory-plane-dedup-skips-health");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Two near-identical health events — they MUST stay separate.
        // Two doses of the same medication are distinct events even if
        // the text is the same.
        let dose1 = mgr
            .add_entry(
                "health_medication",
                "user",
                &[],
                None,
                60,
                "Tomé metformina 500mg con el desayuno",
            )
            .await
            .unwrap();
        let dose2 = mgr
            .add_entry(
                "health_medication",
                "user",
                &[],
                None,
                60,
                "Tomé metformina 500mg con el desayuno",
            )
            .await
            .unwrap();

        // Aggressive dedup threshold — would normally fuse identical text.
        let merged = mgr.dedup_similar(0.5).await.unwrap();

        // Both must survive.
        let db = MemoryPlaneManager::open_db(&dir.join(DB_FILE)).unwrap();
        let count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE entry_id IN (?1, ?2)",
                params![dose1.entry_id, dose2.entry_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2, "Both health doses must survive dedup");
        assert_eq!(
            merged, 0,
            "dedup must report 0 merges when only health pairs are eligible"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_search_archived_finds_archived_entries() {
        let dir = temp_dir("memory-plane-search-archived");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Insert two entries with the same topic.
        let live = mgr
            .add_entry(
                "note",
                "user",
                &[],
                None,
                40,
                "Idea fresca: hacer una app de listas de mercado",
            )
            .await
            .unwrap();
        let old = mgr
            .add_entry(
                "note",
                "user",
                &[],
                None,
                5,
                "Idea vieja: hacer una app de listas de mercado",
            )
            .await
            .unwrap();
        // Force the old one to be archived via decay.
        backdate(&dir, &old.entry_id, 100);
        let _ = mgr.apply_decay().await.unwrap();

        // Live search must NOT return the archived entry.
        let live_results = mgr
            .search_entries("listas de mercado", 10, None)
            .await
            .unwrap();
        let live_ids: Vec<&str> = live_results
            .iter()
            .map(|r| r.entry.entry_id.as_str())
            .collect();
        assert!(live_ids.contains(&live.entry_id.as_str()));
        assert!(
            !live_ids.contains(&old.entry_id.as_str()),
            "Live search must exclude archived entry"
        );

        // Archive search MUST return it.
        let archived_results = mgr
            .search_archived("listas de mercado", 10, None)
            .await
            .unwrap();
        let arch_ids: Vec<&str> = archived_results
            .iter()
            .map(|r| r.entry.entry_id.as_str())
            .collect();
        assert!(
            arch_ids.contains(&old.entry_id.as_str()),
            "Archive search must return the archived entry, got {:?}",
            arch_ids
        );
        // And the live entry must NOT show up in the archive search.
        assert!(!arch_ids.contains(&live.entry_id.as_str()));

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- BI.2: Salud médica estructurada -----------------------------------

    #[tokio::test]
    async fn test_health_fact_add_and_list() {
        let dir = temp_dir("memory-plane-health-facts");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let fact = mgr
            .add_health_fact(
                "allergy",
                "Penicilina",
                Some("severe"),
                "Reaccion en el hospital en 2024",
                None,
            )
            .await
            .unwrap();
        assert_eq!(fact.fact_type, "allergy");
        assert_eq!(fact.severity.as_deref(), Some("severe"));
        assert_eq!(fact.notes, "Reaccion en el hospital en 2024");

        // Add a second one of a different type.
        mgr.add_health_fact("blood_type", "O+", None, "", None)
            .await
            .unwrap();

        // List all.
        let all = mgr.list_health_facts(None).await.unwrap();
        assert_eq!(all.len(), 2);

        // Filter by type.
        let allergies = mgr.list_health_facts(Some("allergy")).await.unwrap();
        assert_eq!(allergies.len(), 1);
        assert_eq!(allergies[0].label, "Penicilina");
        // Notes survived encryption + decryption.
        assert_eq!(allergies[0].notes, "Reaccion en el hospital en 2024");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_medication_history_lifecycle() {
        let dir = temp_dir("memory-plane-meds-history");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Start with metformina 500mg.
        let m1 = mgr
            .start_medication(
                "Metformina",
                "500mg",
                "cada 12h",
                Some("diabetes tipo 2"),
                Some("Dr. Lopez"),
                "Con la comida",
                None,
            )
            .await
            .unwrap();
        assert!(m1.ended_at.is_none());
        assert_eq!(m1.notes, "Con la comida");

        // Active list = 1.
        let active = mgr.list_active_medications().await.unwrap();
        assert_eq!(active.len(), 1);

        // Stop the original.
        let stopped = mgr.stop_medication(&m1.med_id).await.unwrap();
        assert!(stopped, "stop should return true");

        // Start a new dose.
        let m2 = mgr
            .start_medication(
                "Metformina",
                "850mg",
                "cada 12h",
                Some("diabetes tipo 2"),
                Some("Dr. Lopez"),
                "",
                None,
            )
            .await
            .unwrap();
        assert_ne!(m1.med_id, m2.med_id);

        // Active list = 1 (only m2).
        let active = mgr.list_active_medications().await.unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].med_id, m2.med_id);
        assert_eq!(active[0].dosage, "850mg");

        // Full history = 2 (both rows).
        let history = mgr.list_medication_history().await.unwrap();
        assert_eq!(history.len(), 2);
        // Most-recent-started first (m2).
        assert_eq!(history[0].med_id, m2.med_id);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_stop_medication_idempotent() {
        let dir = temp_dir("memory-plane-meds-stop-idempotent");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let m = mgr
            .start_medication("Sitagliptina", "100mg", "1x dia", None, None, "", None)
            .await
            .unwrap();
        assert!(mgr.stop_medication(&m.med_id).await.unwrap());
        // Second call must return false (already ended).
        assert!(!mgr.stop_medication(&m.med_id).await.unwrap());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_vital_record_and_timeseries() {
        let dir = temp_dir("memory-plane-vitals");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Record 3 glucose readings.
        for v in [110.0_f64, 105.0, 98.0] {
            mgr.record_vital(
                "glucose",
                Some(v),
                None,
                "mg/dL",
                None,
                Some("en ayunas"),
                None,
            )
            .await
            .unwrap();
        }
        // Record an unrelated weight.
        mgr.record_vital("weight", Some(78.5), None, "kg", None, None, None)
            .await
            .unwrap();

        // Glucose timeseries should return exactly 3 entries.
        let glucose = mgr.get_vitals_timeseries("glucose", 100).await.unwrap();
        assert_eq!(glucose.len(), 3);
        for v in &glucose {
            assert_eq!(v.unit, "mg/dL");
            assert_eq!(v.context.as_deref(), Some("en ayunas"));
        }

        // Weight is its own series.
        let weight = mgr.get_vitals_timeseries("weight", 100).await.unwrap();
        assert_eq!(weight.len(), 1);
        assert_eq!(weight[0].value_numeric, Some(78.5));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_vital_requires_value() {
        let dir = temp_dir("memory-plane-vital-requires-value");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let result = mgr
            .record_vital("glucose", None, None, "mg/dL", None, None, None)
            .await;
        assert!(result.is_err(), "vital with no value should fail");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_lab_result_with_reference_range() {
        let dir = temp_dir("memory-plane-labs");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let lab = mgr
            .add_lab_result(
                "HbA1c",
                6.4,
                "%",
                Some(0.0),
                Some(5.7),
                None,
                Some("Salud Digna"),
                "En ayunas",
                None,
                None,
            )
            .await
            .unwrap();
        assert_eq!(lab.test_name, "HbA1c");
        assert_eq!(lab.value_numeric, 6.4);
        assert_eq!(lab.reference_high, Some(5.7));
        assert_eq!(lab.notes, "En ayunas");

        let labs = mgr.list_lab_results(Some("HbA1c"), 10).await.unwrap();
        assert_eq!(labs.len(), 1);
        assert_eq!(labs[0].notes, "En ayunas");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_health_attachment_roundtrip_with_integrity() {
        let dir = temp_dir("memory-plane-attachments");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let plaintext = b"PRESCRIPTION: Metformina 500mg cada 12h. Dr. Lopez.".to_vec();
        let original_len = plaintext.len();

        let att = mgr
            .add_health_attachment(
                "prescription",
                Some("Receta de la consulta del 5 de abril"),
                Some("gripa abril 2026"),
                plaintext.clone(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(att.file_type, "prescription");
        assert!(att.file_path.ends_with(".enc"));

        // The file on disk MUST NOT contain the plaintext.
        let disk_bytes = std::fs::read(&att.file_path).unwrap();
        assert!(!disk_bytes.windows(11).any(|w| w == b"Metformina "));
        assert_ne!(disk_bytes, plaintext);

        // Decrypted contents must match exactly.
        let decrypted = mgr.get_health_attachment(&att.attachment_id).await.unwrap();
        assert_eq!(decrypted, plaintext);
        assert_eq!(decrypted.len(), original_len);

        // Tamper with the file on disk and verify integrity check fires.
        let mut tampered = disk_bytes.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xFF;
        std::fs::write(&att.file_path, &tampered).unwrap();
        let tampered_result = mgr.get_health_attachment(&att.attachment_id).await;
        assert!(
            tampered_result.is_err(),
            "tampered attachment must fail integrity check"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_health_summary_aggregates_everything() {
        let dir = temp_dir("memory-plane-health-summary");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Seed: 1 fact + 1 active med + 2 stopped med + 3 vitals + 1 lab.
        mgr.add_health_fact("allergy", "Latex", Some("moderate"), "", None)
            .await
            .unwrap();

        let m1 = mgr
            .start_medication("Metformina", "500mg", "12h", None, None, "", None)
            .await
            .unwrap();
        mgr.stop_medication(&m1.med_id).await.unwrap();
        mgr.start_medication("Metformina", "850mg", "12h", None, None, "", None)
            .await
            .unwrap();
        mgr.start_medication("Sitagliptina", "100mg", "24h", None, None, "", None)
            .await
            .unwrap();

        for v in [110.0_f64, 105.0, 98.0] {
            mgr.record_vital(
                "glucose", Some(v), None, "mg/dL", None, None, None,
            )
            .await
            .unwrap();
        }

        mgr.add_lab_result(
            "HbA1c",
            6.4,
            "%",
            Some(0.0),
            Some(5.7),
            None,
            None,
            "",
            None,
            None,
        )
        .await
        .unwrap();

        let summary = mgr.get_health_summary(5, 10).await.unwrap();
        assert_eq!(summary.facts.len(), 1);
        // Active medications = 2 (Metformina 850 + Sitagliptina); the
        // 500mg row was stopped.
        assert_eq!(summary.active_medications.len(), 2);
        assert!(summary
            .active_medications
            .iter()
            .all(|m| m.ended_at.is_none()));
        // Recent vitals: 3 glucose readings (only one type registered).
        assert_eq!(summary.recent_vitals.len(), 3);
        assert_eq!(summary.recent_labs.len(), 1);

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- BI.7: Crecimiento personal ----------------------------------------

    #[tokio::test]
    async fn test_book_add_and_status_lifecycle() {
        let dir = temp_dir("memory-plane-books-lifecycle");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let book = mgr
            .add_book(
                "Atomic Habits",
                Some("James Clear"),
                None,
                BookStatus::Reading,
                None,
                "Capitulo 4 me hizo click",
                None,
            )
            .await
            .unwrap();
        assert_eq!(book.status, BookStatus::Reading);
        assert!(book.started_at.is_some());
        assert!(book.finished_at.is_none());
        // Notes encrypted + decrypted roundtrip.
        assert_eq!(book.notes, "Capitulo 4 me hizo click");

        // Mark finished with rating 5.
        let updated = mgr
            .update_book_status(&book.book_id, BookStatus::Finished, Some(5))
            .await
            .unwrap();
        assert!(updated);

        let after = mgr.list_books(None).await.unwrap();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].status, BookStatus::Finished);
        assert_eq!(after[0].rating_1_5, Some(5));
        assert!(after[0].finished_at.is_some());
        assert!(after[0].started_at.is_some(), "started_at must be preserved");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_book_filter_by_status() {
        let dir = temp_dir("memory-plane-books-filter");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        mgr.add_book("A", None, None, BookStatus::Wishlist, None, "", None)
            .await
            .unwrap();
        mgr.add_book("B", None, None, BookStatus::Reading, None, "", None)
            .await
            .unwrap();
        mgr.add_book("C", None, None, BookStatus::Reading, None, "", None)
            .await
            .unwrap();
        mgr.add_book("D", None, None, BookStatus::Finished, Some(4), "", None)
            .await
            .unwrap();

        let reading = mgr.list_books(Some(BookStatus::Reading)).await.unwrap();
        assert_eq!(reading.len(), 2);
        let wishlist = mgr.list_books(Some(BookStatus::Wishlist)).await.unwrap();
        assert_eq!(wishlist.len(), 1);
        let finished = mgr.list_books(Some(BookStatus::Finished)).await.unwrap();
        assert_eq!(finished.len(), 1);
        let all = mgr.list_books(None).await.unwrap();
        assert_eq!(all.len(), 4);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_book_invalid_rating_rejected() {
        let dir = temp_dir("memory-plane-books-bad-rating");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let result = mgr
            .add_book(
                "X",
                None,
                None,
                BookStatus::Finished,
                Some(7),
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_habit_add_and_deactivate() {
        let dir = temp_dir("memory-plane-habit-lifecycle");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let h = mgr
            .add_habit("Meditar 10 min", Some("Por la mañana"), "daily", "", None)
            .await
            .unwrap();
        assert!(h.active);

        let active_before = mgr.list_habits(true).await.unwrap();
        assert_eq!(active_before.len(), 1);

        let deact = mgr.deactivate_habit(&h.habit_id).await.unwrap();
        assert!(deact);
        // Idempotent: second deactivate is a no-op.
        let deact2 = mgr.deactivate_habit(&h.habit_id).await.unwrap();
        assert!(!deact2);

        let active_after = mgr.list_habits(true).await.unwrap();
        assert_eq!(active_after.len(), 0);
        let all = mgr.list_habits(false).await.unwrap();
        assert_eq!(all.len(), 1);
        assert!(!all[0].active);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_habit_checkin_idempotent_per_day() {
        let dir = temp_dir("memory-plane-habit-checkin");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let h = mgr
            .add_habit("Leer 15 min", None, "daily", "", None)
            .await
            .unwrap();

        // Two check-ins for the same date — second one wins (sets to false).
        mgr.log_habit_checkin(&h.habit_id, true, "2026-04-06", Some("Mañana"))
            .await
            .unwrap();
        mgr.log_habit_checkin(&h.habit_id, false, "2026-04-06", Some("Olvide"))
            .await
            .unwrap();

        // The streak query should reflect the latest value (not completed).
        let streak = mgr
            .get_habit_streak(&h.habit_id, "2026-04-06", 1)
            .await
            .unwrap();
        assert_eq!(streak.completed_days, 0);
        assert_eq!(streak.total_days, 1);

        // Now complete it cleanly. Streak should pick it up.
        mgr.log_habit_checkin(&h.habit_id, true, "2026-04-06", None)
            .await
            .unwrap();
        let streak2 = mgr
            .get_habit_streak(&h.habit_id, "2026-04-06", 1)
            .await
            .unwrap();
        assert_eq!(streak2.completed_days, 1);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_habit_streak_window() {
        let dir = temp_dir("memory-plane-habit-streak");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let h = mgr
            .add_habit("Run", None, "daily", "", None)
            .await
            .unwrap();
        // Mark 5 days completed in a 7-day window ending 2026-04-07.
        for d in [
            "2026-04-01",
            "2026-04-02",
            "2026-04-03",
            "2026-04-05",
            "2026-04-07",
        ] {
            mgr.log_habit_checkin(&h.habit_id, true, d, None)
                .await
                .unwrap();
        }
        // Two more days NOT completed within the window.
        mgr.log_habit_checkin(&h.habit_id, false, "2026-04-04", None)
            .await
            .unwrap();
        mgr.log_habit_checkin(&h.habit_id, false, "2026-04-06", None)
            .await
            .unwrap();

        let streak = mgr
            .get_habit_streak(&h.habit_id, "2026-04-07", 7)
            .await
            .unwrap();
        assert_eq!(streak.total_days, 7);
        assert_eq!(streak.completed_days, 5);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_growth_goal_progress_auto_achieves_at_100() {
        let dir = temp_dir("memory-plane-goal-auto-achieve");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let g = mgr
            .add_growth_goal(
                "Aprender Rust",
                Some("Contribuir a un proyecto open source"),
                Some("2026-12-31"),
                "Primer objetivo del año",
                None,
            )
            .await
            .unwrap();
        assert_eq!(g.progress_pct, 0);
        assert_eq!(g.status, GoalStatus::Active);

        // Advance to 60%.
        let updated = mgr
            .update_growth_goal_progress(&g.goal_id, 60, None)
            .await
            .unwrap();
        assert!(updated);

        // Push to 100 — must auto-flip to Achieved.
        mgr.update_growth_goal_progress(&g.goal_id, 100, None)
            .await
            .unwrap();
        let after = mgr
            .list_growth_goals(Some(GoalStatus::Achieved))
            .await
            .unwrap();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].progress_pct, 100);
        assert_eq!(after[0].status, GoalStatus::Achieved);

        // Notes survived encryption.
        assert_eq!(after[0].notes, "Primer objetivo del año");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_growth_goal_progress_clamps_above_100() {
        let dir = temp_dir("memory-plane-goal-clamp");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let g = mgr
            .add_growth_goal("X", None, None, "", None)
            .await
            .unwrap();

        // 200 should be clamped to 100 and auto-achieve.
        mgr.update_growth_goal_progress(&g.goal_id, 200, None)
            .await
            .unwrap();
        let after = mgr.list_growth_goals(None).await.unwrap();
        assert_eq!(after[0].progress_pct, 100);
        assert_eq!(after[0].status, GoalStatus::Achieved);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_growth_summary_aggregates_everything() {
        let dir = temp_dir("memory-plane-growth-summary");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // 1 reading + 2 finished + 1 wishlist
        mgr.add_book("Read1", None, None, BookStatus::Reading, None, "", None)
            .await
            .unwrap();
        mgr.add_book(
            "Done1",
            None,
            None,
            BookStatus::Finished,
            Some(5),
            "",
            None,
        )
        .await
        .unwrap();
        mgr.add_book(
            "Done2",
            None,
            None,
            BookStatus::Finished,
            Some(4),
            "",
            None,
        )
        .await
        .unwrap();
        mgr.add_book("Wish1", None, None, BookStatus::Wishlist, None, "", None)
            .await
            .unwrap();

        // 2 active habits + 1 deactivated
        let h1 = mgr
            .add_habit("Meditar", None, "daily", "", None)
            .await
            .unwrap();
        let h2 = mgr
            .add_habit("Leer", None, "daily", "", None)
            .await
            .unwrap();
        let h3 = mgr
            .add_habit("Correr", None, "weekly:3", "", None)
            .await
            .unwrap();
        mgr.deactivate_habit(&h3.habit_id).await.unwrap();

        // Some check-ins for h1 in the last 30 days ending 2026-04-30.
        for d in ["2026-04-25", "2026-04-26", "2026-04-28", "2026-04-30"] {
            mgr.log_habit_checkin(&h1.habit_id, true, d, None)
                .await
                .unwrap();
        }
        // None for h2.
        let _ = h2;

        // 1 active goal + 1 achieved
        mgr.add_growth_goal("ActiveGoal", None, None, "", None)
            .await
            .unwrap();
        let achieved = mgr
            .add_growth_goal("AchievedGoal", None, None, "", None)
            .await
            .unwrap();
        mgr.update_growth_goal_progress(&achieved.goal_id, 100, None)
            .await
            .unwrap();

        let summary = mgr
            .get_growth_summary(10, "2026-04-30", 30)
            .await
            .unwrap();

        assert_eq!(summary.currently_reading.len(), 1);
        assert_eq!(summary.recently_finished.len(), 2);
        assert_eq!(summary.active_habits.len(), 2);
        assert_eq!(summary.habit_streak_30d.len(), 2);
        // h1 has 4 completed days; h2 has 0.
        let h1_streak = summary
            .habit_streak_30d
            .iter()
            .find(|s| s.habit_id == h1.habit_id)
            .unwrap();
        assert_eq!(h1_streak.completed_days, 4);
        assert_eq!(h1_streak.total_days, 30);
        let h2_streak = summary
            .habit_streak_30d
            .iter()
            .find(|s| s.habit_id == h2.habit_id)
            .unwrap();
        assert_eq!(h2_streak.completed_days, 0);

        // Active goals = 1 (the achieved one is filtered out).
        assert_eq!(summary.active_goals.len(), 1);
        assert_eq!(summary.active_goals[0].name, "ActiveGoal");

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- BI.5: Ejercicio ---------------------------------------------------

    #[tokio::test]
    async fn test_exercise_inventory_lifecycle() {
        let dir = temp_dir("memory-plane-exercise-inventory");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let item = mgr
            .add_exercise_inventory_item(
                "mancuernas ajustables 5-25kg",
                "free_weights",
                2,
                Some("Marca PowerBlock"),
                None,
            )
            .await
            .unwrap();
        assert!(item.active);
        assert_eq!(item.quantity, 2);

        // Add a second item.
        mgr.add_exercise_inventory_item("liga media", "bands", 1, None, None)
            .await
            .unwrap();

        let active = mgr.list_exercise_inventory(true).await.unwrap();
        assert_eq!(active.len(), 2);

        // Deactivate one and verify filtering.
        let deact = mgr.deactivate_inventory_item(&item.item_id).await.unwrap();
        assert!(deact);
        // Idempotent: second deactivate is no-op.
        let deact2 = mgr.deactivate_inventory_item(&item.item_id).await.unwrap();
        assert!(!deact2);

        let after_active = mgr.list_exercise_inventory(true).await.unwrap();
        assert_eq!(after_active.len(), 1);
        let after_all = mgr.list_exercise_inventory(false).await.unwrap();
        assert_eq!(after_all.len(), 2);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_exercise_plan_with_exercises_json_roundtrip() {
        let dir = temp_dir("memory-plane-exercise-plan");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let exercises = vec![
            ExercisePlanItem {
                name: "Press de banca con mancuernas".into(),
                sets_reps: Some("4x10".into()),
                rest_secs: Some(90),
                notes: Some("forma controlada".into()),
            },
            ExercisePlanItem {
                name: "Remo con mancuerna a 1 brazo".into(),
                sets_reps: Some("3x12".into()),
                rest_secs: Some(60),
                notes: None,
            },
            ExercisePlanItem {
                name: "Plancha".into(),
                sets_reps: Some("60s".into()),
                rest_secs: Some(45),
                notes: None,
            },
        ];

        let plan = mgr
            .add_exercise_plan(
                "Empuje + core",
                Some("Sesion de tren superior con core al final"),
                Some("fuerza"),
                Some(3),
                Some(45),
                exercises.clone(),
                Some("axi"),
                "Hecho a la medida del inventario",
                None,
            )
            .await
            .unwrap();
        assert!(plan.active);
        assert_eq!(plan.exercises.len(), 3);
        assert_eq!(plan.exercises[0].name, "Press de banca con mancuernas");
        assert_eq!(plan.exercises[2].sets_reps.as_deref(), Some("60s"));
        assert_eq!(plan.notes, "Hecho a la medida del inventario");

        // Roundtrip via list_exercise_plans (decodes the JSON column).
        let plans = mgr.list_exercise_plans(true).await.unwrap();
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].exercises.len(), 3);
        assert_eq!(plans[0].exercises[1].rest_secs, Some(60));
        // Notes survived encryption.
        assert_eq!(plans[0].notes, "Hecho a la medida del inventario");

        // Deactivate and verify filtering.
        mgr.deactivate_exercise_plan(&plan.plan_id).await.unwrap();
        let active = mgr.list_exercise_plans(true).await.unwrap();
        assert_eq!(active.len(), 0);
        let all = mgr.list_exercise_plans(false).await.unwrap();
        assert_eq!(all.len(), 1);
        assert!(!all[0].active);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_exercise_plan_requires_at_least_one_exercise() {
        let dir = temp_dir("memory-plane-exercise-plan-empty");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let result = mgr
            .add_exercise_plan(
                "X",
                None,
                None,
                None,
                None,
                vec![],
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_exercise_log_session_validation() {
        let dir = temp_dir("memory-plane-exercise-log-validation");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // duration_min = 0 must error.
        let result = mgr
            .log_exercise_session(
                None,
                "strength",
                "test",
                0,
                Some(7),
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        // rpe out of range must error.
        let result = mgr
            .log_exercise_session(
                None,
                "strength",
                "test",
                30,
                Some(15),
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        // Valid call succeeds.
        let session = mgr
            .log_exercise_session(
                None,
                "strength",
                "test",
                45,
                Some(7),
                None,
                "Buen dia",
                None,
            )
            .await
            .unwrap();
        assert_eq!(session.duration_min, 45);
        assert_eq!(session.rpe_1_10, Some(7));
        assert_eq!(session.notes, "Buen dia");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_exercise_log_recent_sessions_ordering() {
        let dir = temp_dir("memory-plane-exercise-log-order");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Insert 3 sessions with explicit timestamps to control order.
        let t1 = Utc::now() - chrono::Duration::days(3);
        let t2 = Utc::now() - chrono::Duration::days(1);
        let t3 = Utc::now();

        for (t, desc) in [(t1, "oldest"), (t2, "middle"), (t3, "newest")] {
            mgr.log_exercise_session(
                None,
                "cardio",
                desc,
                30,
                None,
                Some(t),
                "",
                None,
            )
            .await
            .unwrap();
        }

        let sessions = mgr.list_exercise_sessions(50).await.unwrap();
        assert_eq!(sessions.len(), 3);
        // Newest first.
        assert_eq!(sessions[0].description, "newest");
        assert_eq!(sessions[1].description, "middle");
        assert_eq!(sessions[2].description, "oldest");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_exercise_summary_aggregates_everything() {
        let dir = temp_dir("memory-plane-exercise-summary");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // 2 inventory items + 1 deactivated.
        mgr.add_exercise_inventory_item("mancuernas", "free_weights", 2, None, None)
            .await
            .unwrap();
        mgr.add_exercise_inventory_item("banca", "free_weights", 1, None, None)
            .await
            .unwrap();
        let dead = mgr
            .add_exercise_inventory_item("liga rota", "bands", 1, None, None)
            .await
            .unwrap();
        mgr.deactivate_inventory_item(&dead.item_id).await.unwrap();

        // 1 active plan + 1 deactivated.
        mgr.add_exercise_plan(
            "Plan A",
            None,
            Some("fuerza"),
            Some(3),
            Some(45),
            vec![ExercisePlanItem {
                name: "Press".into(),
                sets_reps: Some("4x10".into()),
                rest_secs: Some(90),
                notes: None,
            }],
            None,
            "",
            None,
        )
        .await
        .unwrap();
        let dead_plan = mgr
            .add_exercise_plan(
                "Plan viejo",
                None,
                None,
                None,
                None,
                vec![ExercisePlanItem {
                    name: "Algo".into(),
                    sets_reps: None,
                    rest_secs: None,
                    notes: None,
                }],
                None,
                "",
                None,
            )
            .await
            .unwrap();
        mgr.deactivate_exercise_plan(&dead_plan.plan_id).await.unwrap();

        // Sessions: 2 within last 7 days, 1 more within last 30 days,
        // 1 older than 30 days.
        let now = Utc::now();
        let in_7d_a = now - chrono::Duration::days(2);
        let in_7d_b = now - chrono::Duration::days(5);
        let in_30d = now - chrono::Duration::days(20);
        let old = now - chrono::Duration::days(40);

        for (t, mins) in [
            (in_7d_a, 45_u32),
            (in_7d_b, 30),
            (in_30d, 60),
            (old, 90),
        ] {
            mgr.log_exercise_session(
                None,
                "strength",
                "session",
                mins,
                Some(7),
                Some(t),
                "",
                None,
            )
            .await
            .unwrap();
        }

        let summary = mgr.get_exercise_summary(50).await.unwrap();

        assert_eq!(summary.inventory.len(), 2);
        assert_eq!(summary.active_plans.len(), 1);
        // 4 sessions stored, all returned (limit 50).
        assert_eq!(summary.recent_sessions.len(), 4);
        assert_eq!(summary.sessions_last_7_days, 2);
        assert_eq!(summary.sessions_last_30_days, 3);
        assert_eq!(summary.total_minutes_last_30_days, 45 + 30 + 60);

        std::fs::remove_dir_all(dir).ok();
    }

    // ---- BI.3 sprint 1: Nutricion ------------------------------------------

    #[tokio::test]
    async fn test_nutrition_preference_lifecycle() {
        let dir = temp_dir("memory-plane-nutrition-pref");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let allergy = mgr
            .add_nutrition_preference(
                "allergy",
                "mariscos",
                Some("severe"),
                "Reaccion en restaurante en 2023",
                None,
            )
            .await
            .unwrap();
        assert!(allergy.active);
        assert_eq!(allergy.severity.as_deref(), Some("severe"));
        assert_eq!(allergy.notes, "Reaccion en restaurante en 2023");

        mgr.add_nutrition_preference("diet", "mediterranea", None, "", None)
            .await
            .unwrap();
        mgr.add_nutrition_preference("dislike", "cilantro", None, "", None)
            .await
            .unwrap();

        let all = mgr.list_nutrition_preferences(None, true).await.unwrap();
        assert_eq!(all.len(), 3);

        let allergies = mgr
            .list_nutrition_preferences(Some("allergy"), true)
            .await
            .unwrap();
        assert_eq!(allergies.len(), 1);
        assert_eq!(allergies[0].label, "mariscos");

        // Deactivate the dislike — must drop out of active list.
        let dislike_id = mgr
            .list_nutrition_preferences(Some("dislike"), true)
            .await
            .unwrap()[0]
            .pref_id
            .clone();
        let deact = mgr
            .deactivate_nutrition_preference(&dislike_id)
            .await
            .unwrap();
        assert!(deact);
        let active_after = mgr.list_nutrition_preferences(None, true).await.unwrap();
        assert_eq!(active_after.len(), 2);

        // Idempotent deactivate.
        let deact2 = mgr
            .deactivate_nutrition_preference(&dislike_id)
            .await
            .unwrap();
        assert!(!deact2);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_nutrition_log_meal_validation() {
        let dir = temp_dir("memory-plane-nutrition-log-validation");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // Negative kcal must error.
        let result = mgr
            .log_nutrition_meal(
                "breakfast",
                "test",
                Some(-100.0),
                None,
                None,
                None,
                None,
                None,
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        // NaN must error.
        let result = mgr
            .log_nutrition_meal(
                "breakfast",
                "test",
                Some(f64::NAN),
                None,
                None,
                None,
                None,
                None,
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        // Empty meal_type must error.
        let result = mgr
            .log_nutrition_meal(
                "",
                "test",
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                "",
                None,
            )
            .await;
        assert!(result.is_err());

        // Valid call succeeds.
        let entry = mgr
            .log_nutrition_meal(
                "breakfast",
                "Huevos revueltos con aguacate",
                Some(420.0),
                Some(22.0),
                Some(15.0),
                Some(28.0),
                None,
                None,
                None,
                "Despues de yoga",
                None,
            )
            .await
            .unwrap();
        assert_eq!(entry.macros_kcal, Some(420.0));
        assert_eq!(entry.notes, "Despues de yoga");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_nutrition_log_filter_by_meal_type() {
        let dir = temp_dir("memory-plane-nutrition-log-filter");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        for (mtype, desc) in [
            ("breakfast", "huevos"),
            ("breakfast", "avena"),
            ("lunch", "ensalada"),
            ("dinner", "pollo"),
            ("snack", "manzana"),
        ] {
            mgr.log_nutrition_meal(
                mtype, desc, None, None, None, None, None, None, None, "", None,
            )
            .await
            .unwrap();
        }

        let breakfasts = mgr
            .list_nutrition_log(Some("breakfast"), 50)
            .await
            .unwrap();
        assert_eq!(breakfasts.len(), 2);
        let snacks = mgr.list_nutrition_log(Some("snack"), 50).await.unwrap();
        assert_eq!(snacks.len(), 1);
        let all = mgr.list_nutrition_log(None, 50).await.unwrap();
        assert_eq!(all.len(), 5);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_recipe_with_ingredients_json_roundtrip() {
        let dir = temp_dir("memory-plane-recipe-roundtrip");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let ingredients = vec![
            RecipeIngredient {
                name: "pechuga de pollo".into(),
                amount: 150.0,
                unit: "g".into(),
                notes: Some("sin piel".into()),
            },
            RecipeIngredient {
                name: "arroz integral".into(),
                amount: 80.0,
                unit: "g".into(),
                notes: None,
            },
            RecipeIngredient {
                name: "espinaca".into(),
                amount: 1.0,
                unit: "taza".into(),
                notes: None,
            },
        ];
        let steps = vec![
            "Cocer el arroz".to_string(),
            "Sazonar y asar el pollo".to_string(),
            "Saltear la espinaca".to_string(),
            "Servir junto".to_string(),
        ];
        let tags = vec![
            "alto_proteina".to_string(),
            "almuerzo".to_string(),
        ];

        let recipe = mgr
            .add_recipe(
                "Bowl de pollo y arroz",
                Some("Para post-entreno"),
                ingredients.clone(),
                steps.clone(),
                Some(10),
                Some(25),
                Some(1),
                tags,
                Some("axi"),
                "Receta favorita",
                None,
            )
            .await
            .unwrap();
        assert_eq!(recipe.ingredients.len(), 3);
        assert_eq!(recipe.steps.len(), 4);
        assert_eq!(recipe.tags.len(), 2);
        assert_eq!(recipe.notes, "Receta favorita");

        // Roundtrip via list.
        let listed = mgr.list_recipes(None).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].ingredients.len(), 3);
        assert_eq!(
            listed[0].ingredients[0].name,
            "pechuga de pollo"
        );
        assert_eq!(
            listed[0].ingredients[0].notes.as_deref(),
            Some("sin piel")
        );
        assert_eq!(listed[0].steps[1], "Sazonar y asar el pollo");
        assert_eq!(listed[0].notes, "Receta favorita");

        // Tag filter.
        let filtered = mgr.list_recipes(Some("alto_proteina")).await.unwrap();
        assert_eq!(filtered.len(), 1);
        let none = mgr.list_recipes(Some("postre")).await.unwrap();
        assert_eq!(none.len(), 0);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_recipe_requires_at_least_one_ingredient_and_step() {
        let dir = temp_dir("memory-plane-recipe-empty");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let result_no_ingr = mgr
            .add_recipe(
                "X",
                None,
                vec![],
                vec!["paso 1".into()],
                None,
                None,
                None,
                vec![],
                None,
                "",
                None,
            )
            .await;
        assert!(result_no_ingr.is_err());

        let result_no_steps = mgr
            .add_recipe(
                "X",
                None,
                vec![RecipeIngredient {
                    name: "agua".into(),
                    amount: 1.0,
                    unit: "L".into(),
                    notes: None,
                }],
                vec![],
                None,
                None,
                None,
                vec![],
                None,
                "",
                None,
            )
            .await;
        assert!(result_no_steps.is_err());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_nutrition_plan_lifecycle() {
        let dir = temp_dir("memory-plane-nutrition-plan");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let plan = mgr
            .add_nutrition_plan(
                "Plan mantenimiento",
                Some("30 dias"),
                Some("mantener peso"),
                Some(30),
                Some(2200.0),
                Some(130.0),
                Some(220.0),
                Some(73.0),
                Some("axi"),
                "Recalcular en 30 dias",
                None,
            )
            .await
            .unwrap();
        assert!(plan.active);
        assert_eq!(plan.daily_kcal_target, Some(2200.0));
        assert!(plan.started_at.is_some());

        let active = mgr.list_nutrition_plans(true).await.unwrap();
        assert_eq!(active.len(), 1);

        // Negative kcal target must error.
        let bad = mgr
            .add_nutrition_plan(
                "Bad",
                None,
                None,
                None,
                Some(-1.0),
                None,
                None,
                None,
                None,
                "",
                None,
            )
            .await;
        assert!(bad.is_err());

        // Deactivate.
        let deact = mgr.deactivate_nutrition_plan(&plan.plan_id).await.unwrap();
        assert!(deact);
        let after = mgr.list_nutrition_plans(true).await.unwrap();
        assert_eq!(after.len(), 0);
        let all = mgr.list_nutrition_plans(false).await.unwrap();
        assert_eq!(all.len(), 1);
        assert!(!all[0].active);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_nutrition_summary_aggregates_everything() {
        let dir = temp_dir("memory-plane-nutrition-summary");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        // 1 active allergy + 1 deactivated dislike.
        mgr.add_nutrition_preference("allergy", "mariscos", Some("severe"), "", None)
            .await
            .unwrap();
        let dis = mgr
            .add_nutrition_preference("dislike", "cilantro", None, "", None)
            .await
            .unwrap();
        mgr.deactivate_nutrition_preference(&dis.pref_id)
            .await
            .unwrap();

        // 1 active plan.
        mgr.add_nutrition_plan(
            "Plan A",
            None,
            Some("mantener"),
            Some(30),
            Some(2000.0),
            Some(120.0),
            Some(200.0),
            Some(70.0),
            None,
            "",
            None,
        )
        .await
        .unwrap();

        // 4 meals: 3 within last 7 days, 1 older.
        let now = Utc::now();
        let meals = [
            (now - chrono::Duration::days(1), 500.0_f64, 30.0_f64, 50.0_f64, 18.0_f64),
            (now - chrono::Duration::days(3), 600.0, 35.0, 60.0, 22.0),
            (now - chrono::Duration::days(6), 450.0, 25.0, 45.0, 15.0),
            (now - chrono::Duration::days(20), 700.0, 40.0, 70.0, 25.0),
        ];
        for (when, k, p, c, f) in meals {
            mgr.log_nutrition_meal(
                "lunch",
                "comida",
                Some(k),
                Some(p),
                Some(c),
                Some(f),
                None,
                None,
                Some(when),
                "",
                None,
            )
            .await
            .unwrap();
        }

        let summary = mgr.get_nutrition_summary(50).await.unwrap();

        // Active prefs: 1 (allergy only — dislike is deactivated).
        assert_eq!(summary.preferences.len(), 1);
        assert_eq!(summary.preferences[0].pref_type, "allergy");

        assert!(summary.active_plan.is_some());
        assert_eq!(summary.active_plan.as_ref().unwrap().name, "Plan A");

        // All 4 meals returned (limit 50).
        assert_eq!(summary.recent_meals.len(), 4);

        // Rolling 7-day totals: 3 meals, 1550 kcal, 90g protein, etc.
        assert_eq!(summary.meals_last_7_days, 3);
        assert!((summary.kcal_last_7_days - 1550.0).abs() < 0.01);
        assert!((summary.protein_g_last_7_days - 90.0).abs() < 0.01);
        assert!((summary.carbs_g_last_7_days - 155.0).abs() < 0.01);
        assert!((summary.fat_g_last_7_days - 55.0).abs() < 0.01);

        std::fs::remove_dir_all(dir).ok();
    }
}
