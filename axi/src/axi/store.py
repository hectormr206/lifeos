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
        c = sqlcipher3.connect(
            str(DB_PATH), check_same_thread=False, isolation_level=None
        )
        # PRAGMA key MUST come first or SQLCipher treats the file as unkeyed.
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA foreign_keys=ON")
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


def close() -> None:
    global _conn
    with _conn_lock:
        if _conn is not None:
            _conn.close()
            _conn = None
