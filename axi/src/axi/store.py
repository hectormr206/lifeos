"""SQLite-based knowledge store for Axi.

Pattern: "property graph in SQLite" — `nodes` (entities/facts/events),
`edges` (relationships), `conversations` (chat turns, with bridge to a
node when worth promoting to long-term memory), and full-text search
on top via FTS5.

Plus per-domain structured tables (health, finance, …). The graph is
the semantic layer; the domain tables are the authoritative numeric/
temporal records. Bridge via `node_id` foreign keys.

The DB is a single file at `~/.local/state/axi/memory.db`. WAL mode is
enabled for safe concurrent access from the daemon and (future) other
modules / a dashboard.
"""
from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import sqlite3
import stat
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

log = logging.getLogger("axi.store")

import sqlcipher3

STATE_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi"
DB_PATH = STATE_DIR / "memory.db"

_SCHEMA = r"""
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA synchronous=NORMAL;

-- ──────────────────────────── core graph ────────────────────────────

CREATE TABLE IF NOT EXISTS nodes (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT NOT NULL,         -- 'person'|'fact'|'event'|'conversation'|'medication'|'symptom'|'bp_reading'|...
  label       TEXT NOT NULL,         -- short human-readable name
  data        TEXT,                  -- JSON blob of type-specific props
  domain      TEXT,                  -- 'health'|'finance'|'work'|'home'|… or NULL
  created_at  REAL NOT NULL,         -- Unix epoch (absolute moment, UTC)
  updated_at  REAL NOT NULL,
  created_tz  TEXT                   -- IANA timezone active when this node was created
);
CREATE INDEX IF NOT EXISTS idx_nodes_kind    ON nodes(kind);
CREATE INDEX IF NOT EXISTS idx_nodes_domain  ON nodes(domain);
CREATE INDEX IF NOT EXISTS idx_nodes_created ON nodes(created_at);

CREATE TABLE IF NOT EXISTS edges (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  from_id     INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  to_id       INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,         -- 'mentioned_in'|'caused_by'|'happened_after'|'belongs_to'|'supersedes'|…
  data        TEXT,                  -- JSON props
  created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_edges_from ON edges(from_id);
CREATE INDEX IF NOT EXISTS idx_edges_to   ON edges(to_id);
CREATE INDEX IF NOT EXISTS idx_edges_kind ON edges(kind);

-- ─────────────────────── conversation history ───────────────────────

CREATE TABLE IF NOT EXISTS conversations (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  ts              REAL NOT NULL,
  user_text       TEXT NOT NULL,
  axi_text        TEXT NOT NULL,
  session_id      TEXT,              -- group consecutive turns (V2: smart sessioning)
  has_screenshot  INTEGER DEFAULT 0,
  node_id         INTEGER REFERENCES nodes(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_conv_ts      ON conversations(ts);
CREATE INDEX IF NOT EXISTS idx_conv_session ON conversations(session_id);

-- ─────────────────────────── full-text search ───────────────────────

CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
  label,
  data_text,
  tokenize = 'unicode61 remove_diacritics 2'
);
-- Contentless variant; we INSERT manually. Could move to triggers later.

-- ──────────────────────────── meetings ─────────────────────────────

CREATE TABLE IF NOT EXISTS meetings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  start_time   REAL NOT NULL,
  end_time     REAL,
  title        TEXT,
  source       TEXT,                 -- 'meet'|'zoom'|'manual'|…
  detected_app TEXT,                 -- 'brave'|'chrome'|… (when auto-detected)
  data_dir     TEXT NOT NULL,        -- absolute path to chunks/screens
  transcript   TEXT,
  summary      TEXT,
  status       TEXT NOT NULL DEFAULT 'recording',  -- 'recording'|'processing'|'done'|'failed'
  mic_source   TEXT,                 -- PA source name used for mic capture
  system_sink  TEXT,                 -- PA sink whose monitor we recorded
  node_id      INTEGER REFERENCES nodes(id) ON DELETE SET NULL,
  created_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_meetings_start ON meetings(start_time);
CREATE INDEX IF NOT EXISTS idx_meetings_status ON meetings(status);

CREATE TABLE IF NOT EXISTS meeting_segments (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id     INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  channel        TEXT NOT NULL,      -- 'mic' | 'system'
  chunk_path     TEXT NOT NULL,      -- relative to meetings.data_dir
  start_ms       INTEGER NOT NULL,   -- ms since meeting start
  end_ms         INTEGER NOT NULL,
  text           TEXT,
  speaker_label  TEXT,               -- 'Héctor' for mic, user-assigned for system
  created_at     REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_segments_meeting ON meeting_segments(meeting_id);

CREATE TABLE IF NOT EXISTS meeting_screenshots (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id   INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  filename     TEXT NOT NULL,        -- relative to meetings.data_dir
  start_ms     INTEGER NOT NULL,     -- ms since meeting start
  phash        INTEGER,              -- 64-bit perceptual hash for dedup
  created_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_screens_meeting ON meeting_screenshots(meeting_id, start_ms);

-- ──────────────────────── speakers (cross-meeting) ────────────────

CREATE TABLE IF NOT EXISTS speakers (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  name            TEXT NOT NULL,        -- 'Sergio', 'Sully'… defaults to 'Persona N' until renamed
  embedding       BLOB,                  -- 256-dim float32 voice embedding (average of all seen utterances)
  embedding_count INTEGER DEFAULT 1,     -- how many utterances are averaged into `embedding`
  created_at      REAL NOT NULL,
  updated_at      REAL NOT NULL
);

-- Per-meeting cluster → global speaker map. A meeting may have 3 clusters,
-- each linked to a speaker (existing or freshly created during processing).
CREATE TABLE IF NOT EXISTS meeting_speakers (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id  INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  cluster_id  INTEGER NOT NULL,         -- 0, 1, 2… within this meeting
  speaker_id  INTEGER REFERENCES speakers(id) ON DELETE SET NULL,
  created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_meeting_speakers_meeting ON meeting_speakers(meeting_id);

-- ────────────────────────── reminders (cross-domain) ───────────────

CREATE TABLE IF NOT EXISTS reminders (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  ts               REAL NOT NULL,    -- when to fire (next occurrence)
  message          TEXT NOT NULL,
  channel          TEXT NOT NULL DEFAULT 'notify',  -- 'notify'|'voice'|'both'
  repeat           TEXT,             -- 'daily'|'weekly'|'monthly'|NULL
  related_node_id  INTEGER REFERENCES nodes(id) ON DELETE SET NULL,
  domain           TEXT,
  fired_at         REAL,
  acknowledged_at  REAL,
  created_at       REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reminders_ts ON reminders(ts);

-- ───────────────── meeting segments FTS (P1.1) ─────────────────────

CREATE VIRTUAL TABLE IF NOT EXISTS meeting_segments_fts USING fts5(
  meeting_id UNINDEXED,
  speaker,
  text,
  start_ms UNINDEXED,
  screenshot_path UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

-- ────────────────────────── events (P0.1) ─────────────────────────

CREATE TABLE IF NOT EXISTS events (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        REAL NOT NULL,
  source    TEXT NOT NULL,
  level     TEXT NOT NULL,
  message   TEXT NOT NULL,
  data_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts    ON events(ts DESC);
CREATE INDEX IF NOT EXISTS idx_events_level ON events(level);

-- ───────────────────── brain metrics (P0.2) ───────────────────────

CREATE TABLE IF NOT EXISTS brain_metrics (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  ts                REAL NOT NULL,
  latency_ms        INTEGER NOT NULL,
  model             TEXT,
  prompt_tokens     INTEGER,
  completion_tokens INTEGER,
  total_tokens      INTEGER,
  ok                INTEGER NOT NULL DEFAULT 1,
  error             TEXT
);
CREATE INDEX IF NOT EXISTS idx_brain_metrics_ts ON brain_metrics(ts DESC);

-- ─────────────────── schema version (migrations later) ──────────────

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
"""

_conn: sqlite3.Connection | None = None
_conn_lock = threading.Lock()
_init_lock = threading.Lock()


def key_path() -> Path:
    """Path to the at-rest encryption key for the memory store."""
    return STATE_DIR / "memory.key"


def load_key() -> str:
    """Read or generate the hex-encoded SQLCipher key.

    First call generates 32 random bytes, persists them hex-encoded, and
    tightens permissions to 600. Subsequent calls just read the file.
    Per-process caching is acceptable — key rotation requires a restart.
    """
    kp = key_path()
    kp.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if kp.exists():
        return kp.read_text().strip()
    key = secrets.token_bytes(32).hex()
    kp.write_text(key)
    try:
        kp.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 600
    except OSError:
        pass
    return key


def _try_open(db_path: Path, key: str) -> sqlcipher3.Connection | None:
    """Open *db_path* with *key* and run a quick integrity probe.

    Returns the connection on success, None if the file is missing, or raises
    ``sqlcipher3.dbapi2.DatabaseError`` if the file is malformed/unreadable.
    """
    if not db_path.exists():
        return None
    c = sqlcipher3.connect(str(db_path), check_same_thread=False, isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    # A single read forces SQLCipher to decrypt the first page; this is the
    # operation that raises "database disk image is malformed" on corruption.
    c.execute("SELECT count(*) FROM sqlite_master").fetchone()
    return c


def _remove_wal_sidecars(db_path: Path) -> None:
    """Delete -wal and -shm sidecar files for *db_path* if they exist."""
    for suffix in ("-wal", "-shm"):
        Path(str(db_path) + suffix).unlink(missing_ok=True)


def _repair_corrupt_db(db_path: Path, key: str) -> sqlcipher3.Connection:
    """Recovery ladder for a corrupt memory.db.

    Steps (each step is only attempted if the previous fails):
    1. Back up the corrupt files to .corrupt-<pid>.bak.
    2. Remove the WAL/SHM sidecars and retry the open (WAL-only corruption —
       the most common case after a hard kill).
    3. Restore the newest known-clean backup that passes integrity_check.
    4. Build a fresh empty schema so Axi starts with empty memory rather than
       crashing.

    All steps are logged. Raises only if even a fresh schema cannot be built.
    """
    pid = os.getpid()
    bak = db_path.parent / f"{db_path.name}.corrupt-{pid}.bak"
    log.warning("corrupt memory DB detected — starting recovery (backup → %s)", bak)

    # Step 1 — back up corrupt files.
    try:
        if db_path.exists():
            shutil.copy2(str(db_path), str(bak))
        for suffix in ("-wal", "-shm"):
            src = Path(str(db_path) + suffix)
            if src.exists():
                shutil.copy2(str(src), str(bak) + suffix)
    except OSError as backup_err:
        log.warning("recovery: could not write backup (%s) — continuing", backup_err)

    # Step 2 — WAL reset: remove sidecars and retry (handles WAL-only corruption).
    _remove_wal_sidecars(db_path)
    try:
        conn = _try_open(db_path, key)
        if conn is not None:
            log.warning("recovery: WAL reset succeeded — memory DB is healthy again")
            return conn
    except sqlcipher3.dbapi2.DatabaseError:
        log.warning("recovery: WAL reset was not sufficient — trying backup restore")

    # Step 3 — restore newest known-clean backup.
    clean_backups = sorted(
        db_path.parent.glob(f"{db_path.name}*.bak"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for candidate in clean_backups:
        # Skip the corrupt backup we just wrote.
        if ".corrupt-" in candidate.name:
            continue
        try:
            shutil.copy2(str(candidate), str(db_path))
            _remove_wal_sidecars(db_path)
            conn = _try_open(db_path, key)
            if conn is not None:
                log.warning("recovery: restored from backup %s", candidate.name)
                return conn
        except (OSError, sqlcipher3.dbapi2.DatabaseError):
            log.warning("recovery: backup %s is also corrupt — skipping", candidate.name)

    # Step 4 — last resort: rebuild an empty schema.
    log.warning("recovery: no clean backup found — rebuilding empty memory DB")
    db_path.unlink(missing_ok=True)
    _remove_wal_sidecars(db_path)
    conn = sqlcipher3.connect(str(db_path), check_same_thread=False, isolation_level=None)
    conn.execute(f"PRAGMA key = \"x'{key}'\"")
    return conn


def _connect() -> sqlcipher3.Connection:
    global _conn
    if _conn is not None:
        return _conn
    with _conn_lock:
        if _conn is not None:
            return _conn
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # One-time, transparent upgrade: an older plaintext memory.db is
        # encrypted in place (backup + atomic swap) before we open it.
        from axi import db_migrate
        db_migrate.migrate_to_encrypted()
        key = load_key()

        try:
            c = _try_open(DB_PATH, key)
            if c is None:
                # DB does not exist yet — create it fresh.
                c = sqlcipher3.connect(
                    str(DB_PATH), check_same_thread=False, isolation_level=None
                )
                c.execute(f"PRAGMA key = \"x'{key}'\"")
        except sqlcipher3.dbapi2.DatabaseError as exc:
            log.warning("memory DB corrupt on open (%s) — attempting auto-recovery", exc)
            c = _repair_corrupt_db(DB_PATH, key)

        # PRAGMA key is already applied by _try_open / _repair_corrupt_db;
        # for fresh connections created inline above we still need WAL + tuning.
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA foreign_keys=ON")
        # FULL durability: each WAL page is flushed before the commit returns.
        # The conversation DB is written ~1x/min so the perf cost is negligible,
        # and it eliminates the partial-WAL-page corruption on hard kills.
        c.execute("PRAGMA synchronous=FULL")
        c.row_factory = sqlcipher3.Row
        try:
            DB_PATH.chmod(stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass
        _conn = c
        return _conn


def init_db() -> None:
    with _init_lock:
        c = _connect()
        c.executescript(_SCHEMA)
        c.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1')")
        # Slice 1: embedding columns + vec_nodes virtual table.
        # migrate_nodes_embedding() and create_vec_nodes_table() are defined later
        # in this module; calling them here ensures they run on every fresh init_db().
        migrate_nodes_embedding()
        try:
            create_vec_nodes_table(c)
        except Exception as _vec_exc:  # noqa: BLE001
            log.warning("init_db: could not create vec_nodes table: %s", _vec_exc)


def checkpoint() -> None:
    """Flush the WAL into the main DB file. Non-fatal: logs and swallows errors."""
    try:
        _connect().execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception as e:  # noqa: BLE001
        log.warning("wal_checkpoint failed: %s", e)


@contextmanager
def _tx() -> Iterator[sqlite3.Connection]:
    c = _connect()
    with _conn_lock:
        c.execute("BEGIN")
        try:
            yield c
            c.execute("COMMIT")
        except Exception:
            c.execute("ROLLBACK")
            raise


# ─────────────────────────── graph operations ───────────────────────────

def _current_tz() -> str:
    """Lazy import to avoid axi.config circular dep at module load."""
    from axi import config  # noqa: PLC0415
    return config.get("timezone", "America/Mexico_City")


def add_node(
    kind: str,
    label: str,
    data: dict[str, Any] | None = None,
    domain: str | None = None,
) -> int:
    """Insert a node, mirror text into FTS, return its id."""
    now = time.time()
    payload = json.dumps(data or {}, ensure_ascii=False)
    tz = _current_tz()
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, created_tz) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (kind, label, payload, domain, now, now, tz),
        )
        node_id = cur.lastrowid
        c.execute(
            "INSERT INTO nodes_fts(rowid, label, data_text) VALUES (?, ?, ?)",
            (node_id, label, _fts_text(data or {})),
        )
        return node_id


def add_edge(
    from_id: int,
    to_id: int,
    kind: str,
    data: dict[str, Any] | None = None,
) -> int:
    payload = json.dumps(data or {}, ensure_ascii=False)
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO edges(from_id, to_id, kind, data, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (from_id, to_id, kind, payload, time.time()),
        )
        return cur.lastrowid


def search_nodes_fts(query: str, limit: int = 10) -> list[sqlite3.Row]:
    """FTS5 lexical search over node labels + data text."""
    if not query.strip():
        return []
    c = _connect()
    return list(c.execute(
        "SELECT n.* FROM nodes_fts f "
        "JOIN nodes n ON n.id = f.rowid "
        "WHERE nodes_fts MATCH ? "
        "ORDER BY rank LIMIT ?",
        (query, limit),
    ))


def get_node(node_id: int) -> sqlite3.Row | None:
    c = _connect()
    row = c.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
    return row


def neighbors(node_id: int, edge_kind: str | None = None, depth: int = 1) -> list[sqlite3.Row]:
    """Return nodes connected by outgoing edges; depth=1 for now (V2: recursive CTE)."""
    c = _connect()
    if edge_kind:
        rows = c.execute(
            "SELECT n.* FROM nodes n JOIN edges e ON e.to_id = n.id "
            "WHERE e.from_id = ? AND e.kind = ?",
            (node_id, edge_kind),
        )
    else:
        rows = c.execute(
            "SELECT n.* FROM nodes n JOIN edges e ON e.to_id = n.id "
            "WHERE e.from_id = ?",
            (node_id,),
        )
    return list(rows)


# ─────────────────────────── conversations ─────────────────────────────

def add_conversation(user_text: str, axi_text: str, has_screenshot: bool = False, session_id: str | None = None) -> int:
    """Record a chat turn and return its conversation row id."""
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, session_id, has_screenshot) "
            "VALUES (?, ?, ?, ?, ?)",
            (time.time(), user_text, axi_text, session_id, int(has_screenshot)),
        )
        return cur.lastrowid


def recent_conversations(limit: int = 20) -> list[sqlite3.Row]:
    """Latest turns, OLDEST FIRST for LLM context order."""
    c = _connect()
    rows = list(c.execute(
        "SELECT * FROM conversations ORDER BY ts DESC LIMIT ?", (limit,)
    ))
    return list(reversed(rows))


def clear_conversations() -> int:
    """Wipe chat history. Does NOT touch graph nodes — those are long-term."""
    with _tx() as c:
        cur = c.execute("SELECT COUNT(*) AS n FROM conversations")
        n = cur.fetchone()["n"]
        c.execute("DELETE FROM conversations")
        return n


def conversation_count() -> int:
    c = _connect()
    return c.execute("SELECT COUNT(*) AS n FROM conversations").fetchone()["n"]


# ─────────────────────────── helpers ────────────────────────────────────

def _fts_text(data: dict[str, Any]) -> str:
    """Flatten dict values to a single string for FTS indexing."""
    parts: list[str] = []
    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif v is not None:
            parts.append(str(v))
    walk(data)
    return " ".join(parts)


# ─────────────────────────── events (P0.1) ─────────────────────────────

def insert_event(
    ts: float,
    source: str,
    level: str,
    message: str,
    data_json: str | None,
) -> None:
    """Persist a single event row. Used by `axi.events` background worker."""
    with _tx() as c:
        c.execute(
            "INSERT INTO events(ts, source, level, message, data_json) "
            "VALUES (?, ?, ?, ?, ?)",
            (ts, source, level, message, data_json),
        )


def trim_events(keep: int = 5000) -> None:
    """Keep only the most recent `keep` event rows (delete older)."""
    with _tx() as c:
        c.execute(
            "DELETE FROM events WHERE id NOT IN ("
            "  SELECT id FROM events ORDER BY ts DESC LIMIT ?"
            ")",
            (keep,),
        )


# ─────────────────────── brain metrics (P0.2) ──────────────────────────

def insert_brain_metric(
    ts: float,
    latency_ms: int,
    model: str | None,
    prompt_tokens: int | None,
    completion_tokens: int | None,
    total_tokens: int | None,
    ok: int,
    error: str | None,
) -> None:
    """Persist one brain call metric row. Called from a background thread."""
    with _tx() as c:
        c.execute(
            "INSERT INTO brain_metrics("
            "  ts, latency_ms, model, prompt_tokens, completion_tokens, "
            "  total_tokens, ok, error"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (ts, latency_ms, model, prompt_tokens, completion_tokens,
             total_tokens, ok, error),
        )


def recent_brain_metrics(
    limit: int = 100,
    since_ts: float | None = None,
) -> list[dict[str, Any]]:
    """Most recent brain metrics as dicts, newest first."""
    c = _connect()
    if since_ts is not None:
        rows = c.execute(
            "SELECT id, ts, latency_ms, model, prompt_tokens, completion_tokens, "
            "       total_tokens, ok, error "
            "FROM brain_metrics WHERE ts >= ? "
            "ORDER BY ts DESC LIMIT ?",
            (since_ts, limit),
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT id, ts, latency_ms, model, prompt_tokens, completion_tokens, "
            "       total_tokens, ok, error "
            "FROM brain_metrics "
            "ORDER BY ts DESC LIMIT ?",
            (limit,),
        ).fetchall()
    return [dict(r) for r in rows]


def trim_brain_metrics(keep: int = 5000) -> None:
    """Keep only the most recent `keep` brain metric rows."""
    with _tx() as c:
        c.execute(
            "DELETE FROM brain_metrics WHERE id NOT IN ("
            "  SELECT id FROM brain_metrics ORDER BY ts DESC LIMIT ?"
            ")",
            (keep,),
        )


# ─────────────────── meeting FTS (P1.1) ────────────────────────────────

def init_meeting_fts() -> None:
    """Ensure FTS5 virtual table exists. Already created by init_db() but
    callable separately for explicit migrations."""
    c = _connect()
    c.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS meeting_segments_fts USING fts5("
        "  meeting_id UNINDEXED, speaker, text, start_ms UNINDEXED, "
        "  screenshot_path UNINDEXED, "
        "  tokenize='unicode61 remove_diacritics 2'"
        ")"
    )


def _nearest_screenshot(c: sqlite3.Connection, meeting_id: int, start_ms: int) -> str | None:
    """Return the filename of the screenshot closest to start_ms for the meeting."""
    row = c.execute(
        "SELECT filename FROM meeting_screenshots WHERE meeting_id = ? "
        "ORDER BY ABS(start_ms - ?) ASC LIMIT 1",
        (meeting_id, start_ms),
    ).fetchone()
    return row["filename"] if row else None


def reindex_meeting_segments(meeting_id: int) -> int:
    """Wipe + reinsert FTS rows for a single meeting. Returns count inserted."""
    init_meeting_fts()
    with _tx() as c:
        c.execute(
            "DELETE FROM meeting_segments_fts WHERE meeting_id = ?",
            (meeting_id,),
        )
        rows = c.execute(
            "SELECT meeting_id, speaker_label, text, start_ms "
            "FROM meeting_segments WHERE meeting_id = ? AND text IS NOT NULL",
            (meeting_id,),
        ).fetchall()
        n = 0
        for r in rows:
            shot = _nearest_screenshot(c, meeting_id, int(r["start_ms"]))
            c.execute(
                "INSERT INTO meeting_segments_fts("
                "  meeting_id, speaker, text, start_ms, screenshot_path"
                ") VALUES (?, ?, ?, ?, ?)",
                (
                    meeting_id,
                    r["speaker_label"] or "",
                    r["text"] or "",
                    int(r["start_ms"]),
                    shot or "",
                ),
            )
            n += 1
    return n


def reindex_all_meetings() -> int:
    """Re-index every meeting. Returns number of meetings touched."""
    init_meeting_fts()
    c = _connect()
    rows = c.execute("SELECT id FROM meetings ORDER BY id").fetchall()
    for r in rows:
        try:
            reindex_meeting_segments(int(r["id"]))
        except Exception:  # noqa: BLE001
            # Per-meeting failures should not block the whole migration.
            continue
    return len(rows)


def search_meeting_segments(query: str, limit: int = 20) -> list[dict[str, Any]]:
    """FTS5 search across meeting segments. Empty query → empty list."""
    if not query or not query.strip():
        return []
    init_meeting_fts()
    c = _connect()
    try:
        rows = c.execute(
            "SELECT meeting_id, speaker, start_ms, screenshot_path, "
            "       snippet(meeting_segments_fts, 2, '<b>', '</b>', '…', 16) AS snippet "
            "FROM meeting_segments_fts "
            "WHERE meeting_segments_fts MATCH ? "
            "ORDER BY rank LIMIT ?",
            (query, limit),
        ).fetchall()
    except sqlite3.OperationalError:
        # Malformed FTS query (e.g. unmatched quote). Return empty rather than 500.
        return []
    out = []
    for r in rows:
        out.append({
            "meeting_id": int(r["meeting_id"]),
            "speaker": r["speaker"] or None,
            "snippet": r["snippet"],
            "start_ms": int(r["start_ms"]),
            "screenshot_path": r["screenshot_path"] or None,
        })
    return out


def meeting_in_progress() -> bool:
    """Return True if any meeting has status 'recording' or 'processing'.

    Fail-safe: returns True on any DB error so the caller (heartbeat) does
    NOT start llama-vt during uncertain state, avoiding potential VRAM OOM.
    """
    try:
        c = _connect()
        row = c.execute(
            "SELECT 1 FROM meetings WHERE status IN ('recording','processing') LIMIT 1"
        ).fetchone()
        return row is not None
    except Exception:
        return True  # fail-safe


# ─────────────────── embedding schema migration (Slice 1) ───────────────────


def migrate_nodes_embedding() -> None:
    """Idempotent migration: add embedding columns to the nodes table.

    Adds:
        embedding       BLOB     — float32 vector bytes (struct.pack)
        embedding_model TEXT     — model id that produced the embedding
        embedding_dim   INTEGER  — number of float32 values in embedding

    Existing rows keep NULL for all three columns (backward-compatible).
    Safe to call multiple times (guarded by PRAGMA table_info).
    """
    c = _connect()
    existing = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    new_cols: list[tuple[str, str]] = [
        ("embedding", "BLOB"),
        ("embedding_model", "TEXT"),
        ("embedding_dim", "INTEGER"),
    ]
    for col, col_type in new_cols:
        if col not in existing:
            c.execute(f"ALTER TABLE nodes ADD COLUMN {col} {col_type}")


# ─────────────────── sqlite-vec virtual table (Slice 1, FORK-VEC path A) ────


def _load_sqlite_vec(conn) -> None:
    """Load the sqlite-vec extension into *conn*. Called once per connection open."""
    import sqlite_vec

    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)


def create_vec_nodes_table(conn) -> None:
    """Create the vec_nodes virtual table (float[512]) if it does not exist.

    Uses sqlite-vec (vec0 virtual table engine). The dimensionality 512 matches
    the Matryoshka-512 slice defined in ADR D3. embedding_dim is stored per-node
    so a model swap is detectable (task 4.19).

    Idempotent: safe to call multiple times.
    """
    _load_sqlite_vec(conn)
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS vec_nodes USING vec0("
        "  node_id INTEGER PRIMARY KEY,"
        "  embedding float[512]"
        ")"
    )


def upsert_vec_node(conn, *, node_id: int, vector: list[float]) -> None:
    """Insert or replace a node's embedding in vec_nodes.

    Truncates vector to 512 dims (Matryoshka slice) before storing.
    Caller must commit.
    """
    import struct

    vec = vector[:512]
    blob = struct.pack(f"{len(vec)}f", *vec)
    conn.execute(
        "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
        (node_id, blob),
    )


def knn_nodes(conn, *, vector: list[float], k: int = 10) -> list[int]:
    """Return the k nearest node ids from vec_nodes ordered by cosine distance.

    Returns an empty list if vec_nodes is empty or sqlite-vec is not loaded.
    """
    import struct

    _load_sqlite_vec(conn)
    vec = vector[:512]
    blob = struct.pack(f"{len(vec)}f", *vec)
    try:
        rows = conn.execute(
            "SELECT node_id FROM vec_nodes WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
            (blob, k),
        ).fetchall()
    except Exception:  # noqa: BLE001
        return []
    return [int(r[0]) for r in rows]


# ─────────────────── embed worker (Slice 1) ──────────────────────────────────

# Re-export embed_text from embed_client so store.py callers use a single import,
# and tests can patch "axi.store.embed_text" cleanly.
def embed_text(text: str, *, mode: str = "passage") -> list[float]:
    """Thin wrapper around embed_client.embed — patchable in tests."""
    from axi.embed_client import embed

    return embed(text, mode=mode)  # type: ignore[arg-type]


def embed_pending_nodes(*, limit: int = 100) -> int:
    """Select nodes WHERE embedding IS NULL, embed each, and persist results.

    Mirrors reindex_meeting_segments (store.py:669):
      - Bounded by *limit* (default 100) for rate limiting.
      - Orders by created_at DESC (most recent first, per ADR D4).
      - Single embed failure is logged and skipped; does not abort the batch.
      - Returns the number of nodes successfully embedded.

    Never blocks fact creation — callers should invoke via trigger_embed_for_node
    (fire-and-forget thread) rather than calling this synchronously.
    """
    import struct
    import time as _time

    from axi.embed_client import EmbedServiceError

    c = _connect()
    rows = c.execute(
        "SELECT id, label, data FROM nodes WHERE embedding IS NULL "
        "ORDER BY created_at DESC LIMIT ?",
        (limit,),
    ).fetchall()

    if not rows:
        return 0

    embedded_count = 0
    model_id = "qwen3-embedding-4b"  # read from active_embed_model.json if present
    try:
        from axi.embed_manager import read_active_embed
        cfg = read_active_embed()
        if cfg and "id" in cfg:
            model_id = cfg["id"]
    except Exception:  # noqa: BLE001
        pass

    for row in rows:
        node_id = int(row[0])
        label = row[1] or ""
        data = row[2] or ""
        # Combine label + data text for embedding (passage mode).
        text_to_embed = label if not data or data == "{}" else f"{label} {data}"

        try:
            vector = embed_text(text_to_embed, mode="passage")
        except EmbedServiceError as exc:
            log.debug("embed_pending_nodes: skip node %d — embed failed: %s", node_id, exc)
            continue
        except Exception as exc:  # noqa: BLE001
            log.warning("embed_pending_nodes: unexpected error for node %d: %s", node_id, exc)
            continue

        dim = len(vector)
        blob = struct.pack(f"{dim}f", *vector)

        try:
            with _tx() as txc:
                txc.execute(
                    "UPDATE nodes SET embedding = ?, embedding_model = ?, embedding_dim = ? "
                    "WHERE id = ?",
                    (blob, model_id, dim, node_id),
                )
            # Sync to vec_nodes virtual table (outside _tx: vec0 uses its own txn).
            upsert_vec_node(c, node_id=node_id, vector=vector)
        except Exception as exc:  # noqa: BLE001
            log.warning("embed_pending_nodes: failed to persist embedding for node %d: %s", node_id, exc)
            continue

        embedded_count += 1

    return embedded_count


def trigger_embed_for_node(node_id: int) -> None:
    """Fire-and-forget daemon thread that embeds a single newly inserted node.

    Returns immediately. The embed happens asynchronously so fact creation
    is never blocked (Spec: No Blocking of Fact Creation).
    """

    def _worker(nid: int) -> None:
        try:
            embed_pending_nodes(limit=1)
        except Exception:  # noqa: BLE001
            pass

    t = threading.Thread(target=_worker, args=(node_id,), daemon=True)
    t.start()


# ─────────────────── semantic search (Slice 1) ───────────────────────────────


def semantic_search_nodes(
    query: str,
    *,
    k: int = 20,
    conn=None,
) -> list[dict[str, Any]]:
    """Embed *query* and return nodes ranked by cosine similarity via vec_nodes KNN.

    Returns an empty list if:
      - The embed service is down (EmbedServiceError).
      - vec_nodes is empty or not loaded.

    Never raises — callers receive an empty list on any failure.
    """
    from axi.embed_client import EmbedServiceError

    try:
        vector = embed_text(query, mode="query")
    except EmbedServiceError:
        log.debug("semantic_search_nodes: embed service down for query %r", query)
        return []
    except Exception as exc:  # noqa: BLE001
        log.warning("semantic_search_nodes: unexpected embed error: %s", exc)
        return []

    c = conn or _connect()

    try:
        node_ids = knn_nodes(c, vector=vector, k=k)
    except Exception as exc:  # noqa: BLE001
        log.debug("semantic_search_nodes: knn failed: %s", exc)
        return []

    if not node_ids:
        return []

    # Fetch node metadata in one query, preserving KNN order.
    placeholders = ",".join("?" * len(node_ids))
    rows = c.execute(
        f"SELECT id, kind, label, domain, created_at FROM nodes WHERE id IN ({placeholders})",
        node_ids,
    ).fetchall()

    # Re-order by the KNN rank.
    id_to_row = {int(r[0]): dict(r) for r in rows}
    return [id_to_row[nid] for nid in node_ids if nid in id_to_row]


def close() -> None:
    global _conn
    with _conn_lock:
        if _conn is not None:
            _conn.close()
            _conn = None
