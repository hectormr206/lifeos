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
import queue
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

# Thread-local connection storage: each thread (FastAPI workers, embed worker,
# drain thread, etc.) gets its OWN SQLCipher connection so no two threads ever
# share a connection object.  Concurrent writes are serialized by SQLite's WAL
# file lock + busy_timeout, not by an in-process shared-connection lock.
_tl = threading.local()

# _conn_lock is kept for the one-time global setup (migration, schema init).
# It is NO LONGER used to gate individual SQL statements.
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
    c = sqlcipher3.connect(str(db_path), isolation_level=None)
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
    conn = sqlcipher3.connect(str(db_path), isolation_level=None)
    conn.execute(f"PRAGMA key = \"x'{key}'\"")
    return conn


def _open_new_connection(key: str) -> sqlcipher3.Connection:
    """Open (or create) the DB file and return a fully-configured connection.

    Called once per thread on first use.  Every connection gets:
      - SQLCipher key
      - WAL + FULL synchronous (durability)
      - busy_timeout = 5000 ms (cross-connection WAL write contention retries)
      - sqlite-vec extension loaded (required for any thread touching vec_nodes)
      - row_factory = sqlcipher3.Row
    """
    try:
        c = _try_open(DB_PATH, key)
        if c is None:
            # DB does not exist yet — create it fresh.
            c = sqlcipher3.connect(str(DB_PATH), isolation_level=None)
            c.execute(f"PRAGMA key = \"x'{key}'\"")
    except sqlcipher3.dbapi2.DatabaseError as exc:
        log.warning("memory DB corrupt on open (%s) — attempting auto-recovery", exc)
        c = _repair_corrupt_db(DB_PATH, key)

    # WAL + durability (idempotent — safe to set on every new connection).
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA synchronous=FULL")
    # Retry up to 5 s when another thread (or process) holds the WAL write lock.
    c.execute("PRAGMA busy_timeout=5000")
    c.row_factory = sqlcipher3.Row

    # Load sqlite-vec on every connection so any thread can use vec_nodes.
    try:
        _load_sqlite_vec(c)
    except Exception as _vec_load_exc:  # noqa: BLE001
        log.warning("_open_new_connection: could not load sqlite-vec: %s", _vec_load_exc)

    return c


def _connect() -> sqlcipher3.Connection:
    """Return the SQLCipher connection for the calling thread.

    Each thread owns exactly one connection (created on first use via
    threading.local).  No two threads ever share a connection object, so
    concurrent use of the same connection is impossible by construction.

    Cross-thread write serialization is handled by SQLite's WAL file lock
    and the busy_timeout=5000 set on every connection.
    """
    conn = getattr(_tl, "conn", None)
    if conn is not None:
        return conn

    with _conn_lock:
        # One-time, transparent upgrade: an older plaintext memory.db is
        # encrypted in place (backup + atomic swap) before we open it.
        # Guard with _conn_lock so only one thread runs the migration.
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        from axi import db_migrate
        db_migrate.migrate_to_encrypted()

    key = load_key()
    c = _open_new_connection(key)

    try:
        DB_PATH.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass

    _tl.conn = c
    return c


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
        # Slice 2: domain_node_map bridge table.
        _create_domain_node_map(c)


def checkpoint() -> None:
    """Flush the WAL into the main DB file. Non-fatal: logs and swallows errors."""
    try:
        _connect().execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception as e:  # noqa: BLE001
        log.warning("wal_checkpoint failed: %s", e)


@contextmanager
def _tx() -> Iterator[sqlite3.Connection]:
    """Begin/commit a transaction on the calling thread's own connection.

    No shared lock needed — each thread has its own connection object.
    SQLite WAL + busy_timeout handle cross-thread write serialization.
    """
    c = _connect()
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

    Also creates an AFTER DELETE trigger on nodes that removes the corresponding
    vec_nodes row. SQLite FK ON DELETE CASCADE does NOT propagate to vec0 virtual
    tables, so the trigger is the only safe cleanup path.

    Idempotent: safe to call multiple times.
    """
    _load_sqlite_vec(conn)
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS vec_nodes USING vec0("
        "  node_id INTEGER PRIMARY KEY,"
        "  embedding float[512]"
        ")"
    )
    # AFTER DELETE trigger: clean up vec_nodes when a node is deleted.
    # FK ON DELETE CASCADE does not fire for vec0 virtual tables.
    conn.execute(
        """
        CREATE TRIGGER IF NOT EXISTS trg_nodes_delete_vec
        AFTER DELETE ON nodes
        BEGIN
            DELETE FROM vec_nodes WHERE node_id = OLD.id;
        END
        """
    )


def upsert_vec_node(conn, *, node_id: int, vector: list[float]) -> None:
    """Insert or replace a node's embedding in vec_nodes.

    Truncates vector to 512 dims (Matryoshka slice) before storing.
    vec0 manages its own internal transaction; no external commit needed.
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
            # Sync to vec_nodes virtual table.
            # If this fails, roll back nodes.embedding to NULL so the node stays
            # re-queueable — prevents torn state where embedding IS SET but vec_nodes row
            # is missing, which would exclude the node from future KNN forever.
            try:
                upsert_vec_node(c, node_id=node_id, vector=vector)
            except Exception as vec_exc:  # noqa: BLE001
                log.warning(
                    "embed_pending_nodes: vec_nodes upsert failed for node %d — "
                    "rolling back nodes.embedding to NULL: %s",
                    node_id, vec_exc,
                )
                try:
                    with _tx() as txc2:
                        txc2.execute(
                            "UPDATE nodes SET embedding = NULL, embedding_model = NULL, "
                            "embedding_dim = NULL WHERE id = ?",
                            (node_id,),
                        )
                except Exception as rb_exc:  # noqa: BLE001
                    log.warning(
                        "embed_pending_nodes: rollback of nodes.embedding failed for node %d: %s",
                        node_id, rb_exc,
                    )
                continue
        except Exception as exc:  # noqa: BLE001
            log.warning("embed_pending_nodes: failed to persist embedding for node %d: %s", node_id, exc)
            continue

        embedded_count += 1

    return embedded_count


# ─────────────────── shared embed background worker (FIX 5) ─────────────────
# A bounded queue + single consumer thread replaces the per-node thread spawn.
# trigger_embed_for_node enqueues a signal; the worker drains pending nodes in
# batches.  Idempotent: duplicate signals are silently dropped (queue full).

_EMBED_QUEUE: queue.Queue[int] = queue.Queue(maxsize=500)
_embed_worker_started = threading.Event()
_embed_worker_lock = threading.Lock()


def _embed_worker_loop() -> None:
    """Single consumer thread: drain embed_pending_nodes whenever signalled.

    Blocks on the queue (1 s timeout so the thread wakes periodically).
    On EmbedServiceError: backs off 10 s; nodes remain embedding IS NULL and
    will be retried on the next drain cycle (service-down safe, no lost nodes).
    """
    _BACKOFF_S = 10.0
    _DRAIN_LIMIT = 50  # nodes per drain cycle

    while True:
        try:
            _EMBED_QUEUE.get(timeout=1.0)
            # Drain the queue so we don't process one-at-a-time when bursting.
            while not _EMBED_QUEUE.empty():
                try:
                    _EMBED_QUEUE.get_nowait()
                except queue.Empty:
                    break
        except queue.Empty:
            continue

        try:
            embed_pending_nodes(limit=_DRAIN_LIMIT)
        except Exception:  # noqa: BLE001
            log.debug("embed_worker: drain error — backing off %ss", _BACKOFF_S)
            time.sleep(_BACKOFF_S)


def _ensure_embed_worker() -> None:
    """Start the shared embed consumer thread if it has not been started yet."""
    if _embed_worker_started.is_set():
        return
    with _embed_worker_lock:
        if _embed_worker_started.is_set():
            return
        t = threading.Thread(target=_embed_worker_loop, name="axi-embed-worker", daemon=True)
        t.start()
        _embed_worker_started.set()


def trigger_embed_for_node(node_id: int) -> None:
    """Signal the shared background embed worker that a new node is pending.

    Returns immediately — never blocks fact creation.  The worker thread
    drains embed_pending_nodes(limit=50) in batches.  If the embed service is
    down, nodes stay embedding IS NULL and are retried on the next signal.
    """
    _ensure_embed_worker()
    try:
        _EMBED_QUEUE.put_nowait(node_id)
    except queue.Full:
        # Queue already full — a drain is already scheduled; nothing is lost
        # because embed_pending_nodes selects ALL embedding IS NULL nodes.
        pass


def run_periodic_embed_drain(*, embed_limit: int = 50, similarity_threshold: float = 0.85) -> None:
    """Drain pending embeddings, backfill similar-to edges, and run auto-linkers.

    Intended to be called periodically (e.g. every 5 minutes) from the dashboard
    lifespan background task.  All operations are idempotent and bounded.

    row_factory is set to sqlcipher3.Row before run_auto_linkers so the linker
    dict-access (row["col"]) works correctly regardless of caller state.
    """
    try:
        embed_pending_nodes(limit=embed_limit)
    except Exception:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: embed_pending_nodes failed", exc_info=True)

    try:
        backfill_similar_to_edges(threshold=similarity_threshold)
    except Exception:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: backfill_similar_to_edges failed", exc_info=True)

    try:
        from axi.linkers import run_auto_linkers
        c = _connect()
        # Ensure row_factory is set so linkers can use row["col"] access.
        import sqlcipher3 as _sc3
        c.row_factory = _sc3.Row
        run_auto_linkers(c)
    except Exception:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: run_auto_linkers failed", exc_info=True)


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


# ─────────────────── domain_node_map bridge table (Slice 2) ─────────────────


def _create_domain_node_map(conn) -> None:
    """Create the domain_node_map bridge table if it does not exist.

    domain_node_map links a lifeos domain entry (identified by domain name +
    ULID entry_id) to a System-A fact node in memory.db. The primary key
    (domain, entry_id) ensures uniqueness — no two entries from the same domain
    can map to different nodes, and the same entry can only be bridged once.

    Called from init_db() so every fresh DB has the table from the start.
    """
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS domain_node_map (
            domain      TEXT NOT NULL,
            entry_id    TEXT NOT NULL,
            node_id     INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
            created_at  REAL NOT NULL,
            PRIMARY KEY (domain, entry_id)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_dnm_node_id ON domain_node_map(node_id)"
    )


def upsert_domain_node_map(domain: str, entry_id: str, node_id: int) -> int:
    """Insert or ignore a (domain, entry_id) → node_id mapping.

    Idempotent: if a row already exists for (domain, entry_id), it is left
    unchanged and the existing node_id is returned.

    Returns the node_id (existing or newly inserted).
    """
    with _tx() as c:
        c.execute(
            "INSERT OR IGNORE INTO domain_node_map(domain, entry_id, node_id, created_at) "
            "VALUES (?, ?, ?, ?)",
            (domain, entry_id, node_id, time.time()),
        )
    # Always return the canonical node_id (existing wins on conflict).
    c = _connect()
    row = c.execute(
        "SELECT node_id FROM domain_node_map WHERE domain = ? AND entry_id = ?",
        (domain, entry_id),
    ).fetchone()
    return int(row[0])


def get_node_for_domain_entry(domain: str, entry_id: str) -> int | None:
    """Return the node_id for a (domain, entry_id) pair, or None if not mapped."""
    c = _connect()
    row = c.execute(
        "SELECT node_id FROM domain_node_map WHERE domain = ? AND entry_id = ?",
        (domain, entry_id),
    ).fetchone()
    return int(row[0]) if row else None


# ─────────────────── fact-node creation (Slice 2) ────────────────────────────


def create_fact_node_for_interaction(interaction: Any) -> int:
    """Create a System-A fact node for a lifeos relationships interaction.

    Uses raw_utterance as the node label (truncated to 120 chars).  Falls back
    to interaction.title if raw_utterance is None or empty.  Tags the node with
    domain='relationships', registers the (domain, entry_id) → node_id mapping in
    domain_node_map, and enqueues embedding via trigger_embed_for_node.

    Idempotent: if a mapping already exists for this interaction.id, the existing
    node_id is returned without creating a new node.

    Args:
        interaction: any object with .id, .raw_utterance, .title, .body, .person_id

    Returns:
        The node_id of the fact node (new or existing).
    """
    existing = get_node_for_domain_entry("relationships", interaction.id)
    if existing is not None:
        return existing

    # Build label: prefer raw_utterance (truncated to 120 chars), then title.
    raw = getattr(interaction, "raw_utterance", None)
    label: str
    if raw:
        label = raw[:120]
    else:
        label = (getattr(interaction, "title", None) or "")[:120]

    data: dict[str, Any] = {
        "person_id": getattr(interaction, "person_id", None),
        "interaction_id": interaction.id,
    }
    if getattr(interaction, "body", None):
        data["body"] = interaction.body

    node_id = add_node("fact", label, data=data, domain="relationships")
    upsert_domain_node_map("relationships", interaction.id, node_id)
    trigger_embed_for_node(node_id)
    return node_id


# ─────────────────── similar-to auto-edges (Slice 2) ─────────────────────────


def knn_nodes_with_distance(conn, *, vector: list[float], k: int = 10) -> list[tuple[int, float]]:
    """Return the k nearest node ids with their cosine DISTANCE from vec_nodes.

    vec0 returns cosine DISTANCE (1 - cosine_similarity). Returns list of
    (node_id, distance) tuples ordered by ascending distance (closest first).

    Returns an empty list if vec_nodes is empty or sqlite-vec is not loaded.
    """
    import struct

    _load_sqlite_vec(conn)
    vec = vector[:512]
    blob = struct.pack(f"{len(vec)}f", *vec)
    try:
        rows = conn.execute(
            "SELECT node_id, distance FROM vec_nodes WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
            (blob, k),
        ).fetchall()
    except Exception:  # noqa: BLE001
        return []
    return [(int(r[0]), float(r[1])) for r in rows]


def check_and_create_similar_to_edges(
    node_id: int,
    conn,
    *,
    threshold: float = 0.85,
) -> int:
    """Create 'similar-to' edges from *node_id* to its KNN neighbors above threshold.

    After a node is embedded, run KNN on vec_nodes and insert edges(kind='similar-to')
    for every neighbor whose cosine similarity is >= threshold.

    Rules:
    - No self-links.
    - Idempotent via INSERT OR IGNORE.
    - Uses knn_nodes_with_distance so the threshold can be applied precisely.

    Returns the number of new edges created.
    """
    # Get this node's embedding vector from nodes table.
    row = conn.execute(
        "SELECT embedding, embedding_dim FROM nodes WHERE id = ? AND embedding IS NOT NULL",
        (node_id,),
    ).fetchone()
    if row is None:
        return 0

    import struct

    blob = row[0]
    dim = int(row[1]) if row[1] else 512
    vector = list(struct.unpack(f"{dim}f", blob[:dim * 4]))

    neighbors = knn_nodes_with_distance(conn, vector=vector, k=20)

    created = 0
    for neighbor_id, distance in neighbors:
        if neighbor_id == node_id:
            continue  # no self-link
        cosine_similarity = 1.0 - distance
        if cosine_similarity < threshold:
            continue
        try:
            with _tx() as c:
                exists = c.execute(
                    "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='similar-to' LIMIT 1",
                    (node_id, neighbor_id),
                ).fetchone()
                if exists is None:
                    c.execute(
                        "INSERT INTO edges(from_id, to_id, kind, data, created_at) "
                        "VALUES (?, ?, 'similar-to', '{}', ?)",
                        (node_id, neighbor_id, time.time()),
                    )
                    created += 1
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "check_and_create_similar_to_edges: failed for (%d, %d): %s",
                node_id, neighbor_id, exc,
            )

    return created


# ─────────────────── bounded backfill (Slice 2) ──────────────────────────────


def _fetch_recent_interactions(*, days: int = 90) -> list[Any]:
    """Fetch recent interactions from the relationships domain.

    Pulled via lifeos.relationships.interactions.list_recent. Returns an empty
    list if the relationships DB is unavailable or not yet migrated.
    """
    try:
        from lifeos.relationships import interactions as _rel_interactions
        return _rel_interactions.list_recent(days=days, limit=10_000)
    except Exception as exc:  # noqa: BLE001
        log.warning("_fetch_recent_interactions: failed to load relationships: %s", exc)
        return []


def backfill_domain_fact_nodes(
    *,
    days: int = 90,
    batch_size: int = 50,
    sleep_s: float = 0.1,
) -> int:
    """Bounded backfill: create fact-nodes for recent domain interactions.

    Processes interactions from the relationships domain within the last *days*
    days, creating fact-nodes + domain_node_map entries. Already-mapped entries
    are skipped (resumable). Rate-limited by *batch_size* and *sleep_s*.

    Returns the number of interactions newly bridged.
    """
    import time as _time

    interactions = _fetch_recent_interactions(days=days)
    processed = 0

    for i, interaction in enumerate(interactions):
        # Skip already-mapped entries (idempotent / resumable).
        if get_node_for_domain_entry("relationships", interaction.id) is not None:
            continue

        try:
            create_fact_node_for_interaction(interaction)
            processed += 1
        except Exception as exc:  # noqa: BLE001
            log.warning("backfill_domain_fact_nodes: failed for %s: %s", interaction.id, exc)
            continue

        # Rate limiting: pause after each batch.
        if sleep_s > 0 and processed % batch_size == 0:
            _time.sleep(sleep_s)

    return processed


def backfill_similar_to_edges(*, threshold: float = 0.85) -> int:
    """Create similar-to edges for all nodes that already have embeddings.

    Iterates every node with a non-NULL embedding (that is also present in
    vec_nodes), calling check_and_create_similar_to_edges for each. Idempotent
    via INSERT OR IGNORE in the underlying helper.

    Returns the total number of new edges created across all nodes.
    """
    c = _connect()
    rows = c.execute(
        "SELECT node_id FROM vec_nodes"
    ).fetchall()

    total = 0
    for row in rows:
        nid = int(row[0])
        try:
            total += check_and_create_similar_to_edges(nid, c, threshold=threshold)
        except Exception as exc:  # noqa: BLE001
            log.warning("backfill_similar_to_edges: failed for node %d: %s", nid, exc)

    return total


def close() -> None:
    """Close the calling thread's SQLite connection (if open) and clear it."""
    conn = getattr(_tl, "conn", None)
    if conn is not None:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
        _tl.conn = None
