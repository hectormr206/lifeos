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

import hashlib
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
import traceback
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator

try:
    import fcntl as _fcntl
    _FCNTL_AVAILABLE = True
except ImportError:
    _FCNTL_AVAILABLE = False

log = logging.getLogger("axi.store")

import sqlcipher3

# Process-level gate: when set to "1", "true", or "yes" (case-insensitive),
# all implicit background-worker auto-triggers are suppressed. Explicit
# lifecycle functions (_ensure_embed_worker, stop_embed_worker, etc.) remain
# callable so worker-lifecycle tests still work. Default is OFF (workers
# auto-start normally in production).
_BG_WORKERS_DISABLED = os.environ.get("AXI_DISABLE_BG_WORKERS", "").lower() in ("1", "true", "yes")

# Process-identity opt-in for the embed writer thread.  Default is DISABLED so
# the embed worker thread never starts unless the process explicitly calls
# enable_embed_writer().  Only the daemon process (axi-voice) calls this at
# startup — the dashboard and other readers must never start embed workers
# because they would open concurrent WAL write connections, causing corruption.
_EMBED_WRITER_ENABLED: bool = False

# Interval (seconds) between periodic known-good backup snapshots. Configurable
# via _HEALTHY_BACKUP_INTERVAL_S so tests can override without changing code.
_HEALTHY_BACKUP_INTERVAL_S: int = 1800  # 30 minutes

# Data-loss guard for do_healthy_backup: refuse to overwrite the good healthy
# slots when a key table's row count collapses (a truncation that integrity_check
# cannot see). Growth and small deletions are always allowed.
_GUARD_TABLES: tuple[str, ...] = ("conversations", "nodes", "edges")
_GUARD_MIN_PREV: int = 10       # only guard once the prior backup held real data
_GUARD_DROP_RATIO: float = 0.5  # current < 50% of prior count ⇒ treat as data loss


def enable_embed_writer() -> None:
    """Opt this process in to running the background embed worker thread.

    Must be called once at startup by the daemon process only.  All other
    processes (dashboard, CLI tools) must never call this so embed worker
    threads — which write memory.db — are confined to a single OS process.
    """
    global _EMBED_WRITER_ENABLED
    _EMBED_WRITER_ENABLED = True


class RecoveryError(RuntimeError):
    """Raised when healthy backups exist but every restore attempt failed.

    This signals that recoverable data is present but cannot be written to
    disk (e.g. due to I/O errors). Axi refuses to wipe the database and
    start with an empty schema when data is demonstrably recoverable — a
    loud failure forces human intervention rather than silent data loss.
    """

from axi import events as _events

STATE_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi"
DB_PATH = STATE_DIR / "memory.db"


def _ensure_nocow_dir(path: Path) -> None:
    """Set the NoCoW (Copy-on-Write disabled) attribute on *path* if it exists.

    On btrfs with CoW + compression, SQLite/SQLCipher's many small random
    writes produce "disk I/O error" on read — the proven root fix is to set
    the +C (NoCoW) attribute on the state DIRECTORY so every file created
    inside (memory.db, events.db, future DBs) inherits NoCoW automatically.

    This is best-effort and idempotent:
    - Non-btrfs filesystems (ext4, xfs, tmpfs, APFS) and missing ``chattr``
      binary are silently ignored — startup must never fail on CI or non-btrfs.
    - A plain ``chattr +C`` re-apply on an already-NoCoW dir is a harmless no-op.
    - Only attempted when *path* exists (must be called after mkdir).

    NOTE: lifeos domain DBs in ~/.local/state/lifeos also need the same
    treatment; that should be applied inside the lifeos package on its own
    STATE_DIR, not here.
    """
    if not path.exists():
        return
    try:
        import subprocess as _sp
        _sp.run(
            ["chattr", "+C", str(path)],
            check=False,
            capture_output=True,
        )
    except Exception:
        # Non-btrfs, chattr missing, permission denied, unsupported fs — all OK.
        log.debug("_ensure_nocow_dir: chattr +C skipped for %s (best-effort)", path)


def _apply_nocow(path: Path) -> None:
    """Best-effort ``chattr +C`` on a file or directory to disable CoW on btrfs.

    Non-fatal: silently ignores missing chattr, non-btrfs filesystems, and any
    other OS errors. Used to protect backup files created at runtime so they
    inherit the same NOCOW protection as the main DB.
    """
    try:
        import subprocess as _sp
        _sp.run(["chattr", "+C", str(path)], check=False, capture_output=True)
    except Exception:
        pass


def _events_db_path() -> Path:
    """Path to the separate events (telemetry) DB.

    Events are high-frequency, disposable telemetry written by THREE processes
    (daemon, dashboard, heartbeat). Keeping them in their own SQLCipher file —
    derived from DB_PATH's directory so it follows test monkeypatching — means
    only the daemon ever writes memory.db, eliminating the cross-process WAL
    write contention behind the 2026-06-20 corruption.
    """
    return DB_PATH.parent / "events.db"


_EVENTS_SCHEMA = r"""
-- brain_metrics lives here (events.db), NOT memory.db: it is disposable
-- telemetry written from a background thread on EVERY brain call, including
-- from the dashboard process. Keeping it out of memory.db removes a
-- high-frequency cross-process writer from the precious DB (single-writer
-- hardening — see lifeos/dashboard-db-connection-latch).
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

PRAGMA journal_mode=TRUNCATE;
PRAGMA synchronous=NORMAL;

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
"""

_SCHEMA = r"""
PRAGMA journal_mode=TRUNCATE;
PRAGMA foreign_keys=ON;
-- synchronous is intentionally absent here: _open_new_connection sets
-- PRAGMA synchronous=FULL on every connection and _SCHEMA must not override it.

-- ──────────────────────────── core graph ────────────────────────────

-- PR8 (THE POINT OF NO RETURN): this is mobile's exact v1-base DDL
-- (`mobile/lib/core/graph/local_graph_schema.dart`) — axi converged, mobile
-- did not move. A pre-existing database is brought to this same shape by
-- migrate_rebuild_graph_tables(); a fresh one starts here.
-- The three `embedding*` columns are axi-only LOCAL DERIVED STATE (mobile has
-- no embedder), the same category as nodes_fts/vec_nodes, appended last.
CREATE TABLE IF NOT EXISTS nodes (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- local rowid (per-device)
  uuid         TEXT    NOT NULL UNIQUE,             -- stable sync identity across replicas
  kind         TEXT    NOT NULL,                    -- 'person'|'fact'|'event'|'conversation'|...
  label        TEXT    NOT NULL,                    -- short human-readable name
  data         TEXT,                                -- JSON blob of type-specific props
  domain       TEXT,                                -- 'health'|'finance'|'work'|'home'|… or NULL
  occurred_at  REAL,                                -- real event moment; NULL when unknown
  created_at   REAL    NOT NULL,                    -- graph-insertion time (Unix epoch UTC)
  updated_at   REAL    NOT NULL,
  created_tz   TEXT,                                -- IANA timezone active at creation
  origin_node  TEXT,                                -- sync: replica that authored this row
  lamport      INTEGER NOT NULL DEFAULT 0,          -- sync: logical clock for LWW
  deleted_at   REAL,                                -- sync: tombstone (NULL = live row)
  embedding       BLOB,                             -- axi-only: float32 vector bytes
  embedding_model TEXT,                             -- axi-only: model id
  embedding_dim   INTEGER                           -- axi-only: vector length
);
CREATE INDEX IF NOT EXISTS idx_nodes_kind    ON nodes(kind);
CREATE INDEX IF NOT EXISTS idx_nodes_domain  ON nodes(domain);
CREATE INDEX IF NOT EXISTS idx_nodes_created ON nodes(created_at);
-- SQLite's ALTER TABLE ADD COLUMN cannot attach a UNIQUE constraint, so this
-- index (not a column constraint) is what enforces uuid uniqueness on both a
-- fresh DB (built via this CREATE TABLE) and a migrated pre-existing one
-- (migrate_nodes_edges_sync_columns creates the same index after backfill).
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_uuid ON nodes(uuid);
-- PR7 (tombstones). Mobile's name, verbatim (local_graph_schema.dart), but
-- PARTIAL — and that is not a detail, it is the whole point. Measured with
-- EXPLAIN QUERY PLAN on the queries this PR touches: a FULL index on
-- `deleted_at` gets picked for the `deleted_at IS NULL` filter that every read
-- now carries, and since almost every row IS NULL that "SEARCH" walks the
-- entire table. It cost the graph-browser and recall queries their MULTI-INDEX
-- OR over idx_edges_src/idx_edges_dst — a full scan wearing an index's name,
-- with no test failing and no error. Restricted to `deleted_at IS NOT NULL`,
-- SQLite cannot use it for the live-row filter at all, so the endpoint indexes
-- keep winning, and it stays small and genuinely selective for the query that
-- actually wants it: "which rows are tombstoned" (the sync push).
-- Also created by the migration, so a pre-existing database — which never runs
-- this CREATE TABLE body — gets it too.
CREATE INDEX IF NOT EXISTS idx_nodes_deleted ON nodes(deleted_at)
  WHERE deleted_at IS NOT NULL;

-- PR8: mobile's exact edges DDL. Endpoints are node UUIDs, not local rowids —
-- rowid 42 on the laptop is not rowid 42 on the Pixel, so rowid endpoints
-- cannot sync at all. `relation` is real storage now (it was a generated alias
-- of `kind` during the PR5→PR7 expand window). There is NO foreign key: the
-- `ON DELETE CASCADE` that silently destroyed edges on a hard node delete
-- ceased to exist along with the columns that carried it, and referential
-- integrity moved to the application, matching mobile — where a dangling
-- `src_uuid` is legal by design because an edge may sync before its node.
-- `report_dangling_edges()` is the loud, report-only check that replaces it.
CREATE TABLE IF NOT EXISTS edges (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- local rowid (per-device)
  uuid         TEXT    NOT NULL UNIQUE,             -- stable sync identity
  src_uuid     TEXT    NOT NULL,                    -- source node.uuid
  dst_uuid     TEXT    NOT NULL,                    -- destination node.uuid
  relation     TEXT    NOT NULL,                    -- 'mentioned_in'|'caused_by'|…
  data         TEXT,                                -- JSON props
  created_at   REAL    NOT NULL,
  updated_at   REAL    NOT NULL,
  origin_node  TEXT,                                -- sync: authoring replica
  lamport      INTEGER NOT NULL DEFAULT 0,          -- sync: logical clock
  deleted_at   REAL                                 -- sync: tombstone (NULL = live)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_edges_uuid ON edges(uuid);
-- Names are mobile's, verbatim (local_graph_schema.dart), so there is nothing
-- left to reconcile between the two schemas.
CREATE INDEX IF NOT EXISTS idx_edges_src      ON edges(src_uuid);
CREATE INDEX IF NOT EXISTS idx_edges_dst      ON edges(dst_uuid);
CREATE INDEX IF NOT EXISTS idx_edges_relation ON edges(relation);
CREATE INDEX IF NOT EXISTS idx_edges_deleted  ON edges(deleted_at)
  WHERE deleted_at IS NOT NULL;  -- partial: see idx_nodes_deleted above

-- ─────────────────────── conversation history ───────────────────────

CREATE TABLE IF NOT EXISTS conversations (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  ts              REAL NOT NULL,
  user_text       TEXT NOT NULL,
  axi_text        TEXT NOT NULL,
  session_id      TEXT,              -- group consecutive turns (V2: smart sessioning)
  has_screenshot  INTEGER DEFAULT 0,
  node_id         INTEGER REFERENCES nodes(id) ON DELETE SET NULL,
  source          TEXT DEFAULT 'chat' -- 'chat' | 'voice' — chat view hides 'voice'
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

-- ───────────────────────── chat attachments ───────────────────────
-- Files stored on disk; this table holds metadata + the link back to the
-- conversation turn. conv_id is NULL until the turn is saved (two-phase:
-- upload first, link on send).

CREATE TABLE IF NOT EXISTS chat_attachments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_id     INTEGER REFERENCES conversations(id) ON DELETE CASCADE,
  session_id  TEXT,
  kind        TEXT NOT NULL,
  filename    TEXT NOT NULL,
  mime        TEXT NOT NULL,
  orig_name   TEXT,
  sha256      TEXT,
  size_bytes  INTEGER NOT NULL,
  created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attach_conv ON chat_attachments(conv_id);

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
# Dedicated lock for the one-time events.db migration. MUST be distinct from
# _conn_lock: the migration calls _connect() (which itself takes _conn_lock),
# and threading.Lock is not reentrant, so sharing the lock would deadlock.
_events_migrate_lock = threading.Lock()


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


def _backup_passes_integrity(path: Path, key: str) -> bool:
    """Return True only if *path* opens and passes a full ``integrity_check``.

    Used by the recovery ladder to decide whether a backup candidate is safe to
    restore. We run the FULL ``PRAGMA integrity_check`` (not the light first-page
    probe in :func:`_try_open`) because corruption frequently lives deeper in the
    b-tree than page 1, and — conversely — a file flagged corrupt by one process
    is often perfectly healthy on disk (the damage was WAL-only or cross-process).
    Filename is irrelevant: a ``.corrupt-<pid>.bak`` snapshot is validated by its
    actual contents, never skipped by its name.
    """
    if not path.exists():
        return False
    conn = None
    try:
        conn = sqlcipher3.connect(str(path), isolation_level=None)
        conn.execute(f"PRAGMA key = \"x'{key}'\"")
        result = conn.execute("PRAGMA integrity_check").fetchone()
        return bool(result) and str(result[0]).lower() == "ok"
    except (sqlcipher3.dbapi2.DatabaseError, OSError):
        return False
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001 — closing a probe connection must never raise
                pass


def _emit_recovery_event(level: str, message: str, data: dict | None = None) -> None:
    """Emit a recovery event via events module.

    Double-wrapped: events.py already swallows its own errors, but this
    extra try/except ensures that even a catastrophic failure in the events
    system (e.g. import error, ring-lock corruption) NEVER aborts the DB
    recovery ladder.
    """
    try:
        fn = {
            "critical": _events.log_critical,
            "error": _events.log_error,
            "warning": _events.log_warning,
            "info": _events.log_info,
        }.get(level, _events.log_warning)
        fn("store.corruption", message, data)
    except Exception:  # noqa: BLE001 — events must never abort recovery
        pass


@contextmanager
def _recovery_lock(db_path: Path):
    """Acquire an EXCLUSIVE inter-process flock on a lock file beside *db_path*.

    The lock file is ``Path(str(db_path) + ".recovery.lock")``.  It is created
    if it does not yet exist.  The fd is kept open for the duration of the
    context so the OS releases the lock automatically if the holding process
    dies (flock is tied to the open-file-description).

    Timeout / best-effort:
    - Tries to acquire with ``LOCK_NB`` in a loop, sleeping 0.1 s per attempt,
      for up to 60 s total.
    - If ``fcntl`` is unavailable (non-Linux) or every attempt errors out, logs a
      WARNING and yields without a lock so recovery still proceeds.  The lock
      must NEVER deadlock or raise out of the context manager.

    Usage::

        # Called internally by _repair_corrupt_db, which wraps
        # _repair_corrupt_db_locked inside this context manager.
        with _recovery_lock(db_path):
            return _repair_corrupt_db_locked(db_path, key)
    """
    lock_path = Path(str(db_path) + ".recovery.lock")
    lock_fd = None

    if not _FCNTL_AVAILABLE:
        log.debug("_recovery_lock: fcntl unavailable — proceeding without inter-process lock")
        yield
        return

    try:
        lock_fd = lock_path.open("a+")
        _LOCK_TIMEOUT_S = 60.0
        _SLEEP_S = 0.1
        _max_attempts = int(_LOCK_TIMEOUT_S / _SLEEP_S)
        acquired = False
        hard_error = False  # True when flock itself is unavailable (not just contended)
        for _ in range(_max_attempts):
            try:
                _fcntl.flock(lock_fd.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                time.sleep(_SLEEP_S)
            except OSError as exc:
                # flock genuinely unavailable (e.g. ENOLCK, NFS, unsupported FS).
                # Log once and proceed without the lock; do NOT emit the timeout
                # message below — only one attempt was made, not a full timeout.
                log.warning(
                    "_recovery_lock: flock unavailable (%s) — proceeding without lock",
                    exc,
                )
                hard_error = True
                break

        if not acquired and not hard_error:
            log.warning(
                "_recovery_lock: could not acquire lock on %s within %.0fs "
                "— proceeding without inter-process lock",
                lock_path.name,
                _LOCK_TIMEOUT_S,
            )
    except Exception as exc:  # noqa: BLE001 — lock must never abort recovery
        log.warning(
            "_recovery_lock: failed to open/lock %s (%s) — proceeding without lock",
            lock_path.name,
            exc,
        )
        if lock_fd is not None:
            try:
                lock_fd.close()
            except Exception:  # noqa: BLE001
                pass
        lock_fd = None

    try:
        yield
    finally:
        if lock_fd is not None:
            try:
                _fcntl.flock(lock_fd.fileno(), _fcntl.LOCK_UN)
            except Exception:  # noqa: BLE001
                pass
            try:
                lock_fd.close()
            except Exception:  # noqa: BLE001
                pass


def _repair_corrupt_db(db_path: Path, key: str) -> sqlcipher3.Connection:
    """Recovery ladder for a corrupt memory.db.

    Steps (each step is only attempted if the previous fails):
    1. Back up the corrupt files to .corrupt-<pid>.bak.
    2. Remove the WAL/SHM sidecars and retry the open (WAL-only corruption —
       the most common case after a hard kill).
    3. Restore the newest known-clean backup that passes integrity_check.
    4. Build a fresh empty schema so Axi starts with empty memory rather than
       crashing.

    All steps are logged (stdlib + events ring). Raises only if even a fresh
    schema cannot be built.
    """
    with _recovery_lock(db_path):
        return _repair_corrupt_db_locked(db_path, key)


def _repair_corrupt_db_locked(db_path: Path, key: str) -> sqlcipher3.Connection:
    """Inner recovery body, called only while holding the inter-process flock.

    Immediately re-checks whether the DB is already healthy before running
    any destructive step.  If another process recovered memory.db while this
    process waited for the lock, the re-check succeeds and we return early
    without touching the filesystem.
    """
    # Re-check: another process may have already recovered the DB while we
    # waited for the inter-process lock.  Remove WAL sidecars first (same as
    # Step 2) so the open is not skewed by stale sidecars from the original
    # failure.  If the DB opens cleanly at this point, it is healthy and we
    # can skip all destructive steps.
    #
    # Forensic snapshot: before removing sidecars, best-effort copy any WAL/SHM
    # that are present so corrupt bytes are preserved for post-incident inspection
    # even if the re-check succeeds and we skip Step 1.  This must never abort
    # recovery — wrap in try/except.
    try:
        _forensic_pid = os.getpid()
        _forensic_bak = db_path.parent / f"{db_path.name}.corrupt-{_forensic_pid}.bak"
        for _suffix in ("-wal", "-shm"):
            _src = Path(str(db_path) + _suffix)
            if _src.exists():
                shutil.copy2(str(_src), str(_forensic_bak) + _suffix)
    except Exception:  # noqa: BLE001 — forensic copy must never break recovery
        pass

    try:
        _remove_wal_sidecars(db_path)
        recheck_conn = _try_open(db_path, key)
        if recheck_conn is not None:
            log.warning(
                "recovery: memory.db already healthy (recovered by another process) — skipping"
            )
            _emit_recovery_event(
                "info",
                "recovery: memory.db already healthy after inter-process lock — skipping destructive recovery",
                {"strategy": "recheck_skip", "db_path": str(db_path)},
            )
            return recheck_conn
    except Exception:  # noqa: BLE001 — re-check failure means we proceed normally
        pass

    pid = os.getpid()
    bak = db_path.parent / f"{db_path.name}.corrupt-{pid}.bak"
    log.warning("corrupt memory DB detected — starting recovery (backup → %s)", bak)

    # Detection event — emitted first, before any recovery attempt.
    _emit_recovery_event(
        "critical",
        f"corrupt memory DB detected — starting recovery: {db_path.name}",
        {"db_path": str(db_path), "backup_path": str(bak), "pid": pid},
    )

    # Step 1 — back up corrupt files.
    try:
        if db_path.exists():
            shutil.copy2(str(db_path), str(bak))
        for suffix in ("-wal", "-shm"):
            src = Path(str(db_path) + suffix)
            if src.exists():
                shutil.copy2(str(src), str(bak) + suffix)
        log.warning("recovery: backup written to %s", bak)
        _emit_recovery_event(
            "warning",
            f"recovery step 1: corrupt DB backed up to {bak.name}",
            {"backup_path": str(bak)},
        )
    except OSError as backup_err:
        log.warning("recovery: could not write backup (%s) — continuing", backup_err)
        _emit_recovery_event(
            "warning",
            f"recovery step 1: backup failed ({backup_err}) — continuing",
            {"error": str(backup_err)},
        )

    # Step 2 — WAL reset: remove sidecars and retry (handles WAL-only corruption).
    _remove_wal_sidecars(db_path)
    try:
        conn = _try_open(db_path, key)
        if conn is not None:
            log.warning("recovery: WAL reset succeeded — memory DB is healthy again")
            _emit_recovery_event(
                "warning",
                "recovery step 2: WAL reset succeeded — memory DB is healthy again",
                {"strategy": "wal_reset"},
            )
            return conn
    except sqlcipher3.dbapi2.DatabaseError as wal_err:
        log.warning("recovery: WAL reset was not sufficient — trying backup restore")
        _emit_recovery_event(
            "warning",
            f"recovery step 2: WAL reset failed ({wal_err}) — trying backup restore",
            {"error": str(wal_err)},
        )

    # Step 3 — restore newest backup that passes a FULL integrity check.
    #
    # Validate by CONTENT, never by filename. The step-1 snapshot we just wrote
    # is named ``.corrupt-<pid>.bak`` yet — because corruption is usually
    # WAL-only or cross-process — it is frequently a perfectly healthy copy of
    # the main file. The old code skipped every ``.corrupt-*`` candidate by name
    # and fell through to the empty-schema rebuild, destroying memory that was
    # never actually lost (the 2026-06-20 data-loss incident). Including these
    # snapshots, gated by ``integrity_check``, is what makes recovery safe.
    #
    # Preference order: periodic known-good snapshots (healthy-1.bak → 2 → 3)
    # are tried first because they were validated at write time. Any other .bak
    # files (corrupt-*.bak forensic snapshots, ad-hoc backups) follow by mtime.
    _healthy_slots = [
        db_path.parent / f"{db_path.name}.healthy-{i}.bak"
        for i in (1, 2, 3)
    ]
    _healthy_set = set(_healthy_slots)
    _glob_candidates = sorted(
        [p for p in db_path.parent.glob(f"{db_path.name}*.bak") if p not in _healthy_set],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    candidates = [s for s in _healthy_slots if s.exists()] + _glob_candidates
    # Track whether any candidate passed the integrity check, regardless of
    # whether its subsequent restore succeeded.  This distinguishes "no
    # recoverable data anywhere" (healthy_backup_seen=False → step 4 safe to
    # rebuild empty) from "data exists but disk refuses writes" (True → MUST
    # raise rather than wipe).
    healthy_backup_seen = False
    for candidate in candidates:
        if not _backup_passes_integrity(candidate, key):
            log.warning("recovery: backup %s failed integrity_check — skipping", candidate.name)
            _emit_recovery_event(
                "warning",
                f"recovery step 3: backup {candidate.name} failed integrity_check — skipping",
                {"backup_file": candidate.name},
            )
            continue
        # At least one healthy (integrity-passing) backup exists.
        healthy_backup_seen = True
        # Atomic restore: copy to a temp file, verify it opens, THEN swap in
        # place with os.replace().  Invariant: db_path is never left holding
        # unverified or partial bytes.  The only mutation is an atomic swap to
        # a backup that already passed open-verification.  In the rare case
        # where os.replace succeeds but the subsequent _try_open(db_path) fails,
        # db_path holds verified-good backup bytes — strictly better than the
        # original corrupt content.  Any earlier failure (copy error, temp-open
        # failure) leaves db_path completely untouched.
        tmp = db_path.parent / f"{db_path.name}.restore-tmp-{os.getpid()}-{threading.get_ident()}-{secrets.token_hex(4)}"
        try:
            shutil.copy2(str(candidate), str(tmp))
            verify = _try_open(tmp, key)
            if verify is None:
                tmp.unlink(missing_ok=True)
                log.warning(
                    "recovery: temp restore of %s did not open — skipping",
                    candidate.name,
                )
                _emit_recovery_event(
                    "warning",
                    f"recovery step 3: temp restore of {candidate.name} did not open — skipping",
                    {"backup_file": candidate.name},
                )
                continue
            verify.close()
            # Temp file is verified good.  Clear stale WAL/SHM of the live file
            # BEFORE the atomic swap so readers never see a mismatched WAL.
            _remove_wal_sidecars(db_path)
            os.replace(str(tmp), str(db_path))
            conn = _try_open(db_path, key)
            if conn is not None:
                log.warning("recovery: restored from healthy backup %s", candidate.name)
                _emit_recovery_event(
                    "warning",
                    f"recovery step 3: restored from healthy backup {candidate.name}",
                    {"backup_file": candidate.name, "strategy": "restore_backup"},
                )
                return conn
            # os.replace succeeded but final open failed — unusual (possible
            # concurrent writer); fall through to try next candidate.
            log.warning(
                "recovery: restore of %s: swap succeeded but final open failed — skipping",
                candidate.name,
            )
            _emit_recovery_event(
                "warning",
                f"recovery step 3: restore of {candidate.name}: swap ok but open failed — skipping",
                {"backup_file": candidate.name},
            )
        except (OSError, sqlcipher3.dbapi2.DatabaseError) as cand_err:
            log.warning("recovery: restore of %s failed (%s) — skipping", candidate.name, cand_err)
            _emit_recovery_event(
                "warning",
                f"recovery step 3: restore of {candidate.name} failed ({cand_err}) — skipping",
                {"backup_file": candidate.name, "error": str(cand_err)},
            )
        finally:
            # Never leave a temp file behind regardless of outcome.
            try:
                tmp.unlink(missing_ok=True)
            except Exception:  # noqa: BLE001
                pass

    # Step 4 — last resort: rebuild an empty schema — BUT only when there is
    # genuinely nothing to recover.  If at least one backup passed the integrity
    # check (healthy_backup_seen=True) but every restore failed (e.g. a btrfs
    # I/O error), wiping db_path would destroy recoverable data.  Raise instead
    # so Axi fails loudly and a human can intervene.
    if healthy_backup_seen:
        msg = (
            "recovery aborted: could not bring memory.db back to a healthy open "
            "state from any backup — refusing to wipe memory.db to prevent data "
            "loss; manual recovery required"
        )
        log.error("recovery: %s", msg)
        try:
            _emit_recovery_event(
                "critical",
                f"recovery step 4 ABORTED: {msg}",
                {"strategy": "refuse_wipe", "db_path": str(db_path)},
            )
        except Exception:  # noqa: BLE001 — event emission must never mask the primary error
            pass
        raise RecoveryError(msg)

    log.warning("recovery: no clean backup found — rebuilding empty memory DB")
    # Emit the critical event BEFORE attempting the unlink+connect so it is
    # always recorded even if the step itself fails (e.g. disk full / permissions).
    try:
        _emit_recovery_event(
            "critical",
            "recovery step 4: no clean backup — rebuilding fresh empty schema (all memory lost)",
            {"strategy": "fresh_schema"},
        )
    except Exception:  # noqa: BLE001 — event emission must never abort recovery
        pass
    try:
        db_path.unlink(missing_ok=True)
        _remove_wal_sidecars(db_path)
        conn = sqlcipher3.connect(str(db_path), isolation_level=None)
        conn.execute(f"PRAGMA key = \"x'{key}'\"")
        return conn
    except (OSError, Exception) as exc:  # noqa: BLE001
        try:
            _emit_recovery_event(
                "critical",
                f"recovery step 4 failed: {exc}",
                {"strategy": "fresh_schema", "error": str(exc)},
            )
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(f"recovery step 4 failed: {exc}") from exc


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

    # Rollback-journal (NOT WAL) + durability. memory.db is written by TWO OS
    # processes (dashboard + daemon); SQLCipher's cross-process WAL salt
    # coordination kept latching connections into "hmac check failed pgno=3"
    # on a healthy file. Rollback-journal is SQLite's battle-tested multi-process
    # mode (POSIX file locks, no -wal/-shm, no salt) — it eliminates that race.
    # TRUNCATE keeps one (truncated) journal file instead of create/delete churn
    # on btrfs. Cost: a writer briefly blocks readers (fine for this workload;
    # busy_timeout handles contention). See lifeos/dashboard-db-connection-latch.
    c.execute("PRAGMA journal_mode=TRUNCATE")
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA synchronous=FULL")
    # Retry up to 5 s when another thread (or process) holds the write lock.
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
        # A cached connection is only valid while it still points at the current
        # DB_PATH. In production DB_PATH never changes, so this is always true and
        # the fast path is a single Path comparison. But a FastAPI TestClient
        # runs endpoints in worker threads whose thread-local connection is NOT
        # closed by the test harness swapping DB_PATH between tests — so that
        # thread would keep writing to a previous test's (now removed / re-keyed)
        # temp DB, surfacing as "hmac check failed". Reopen when the path drifts.
        if getattr(_tl, "conn_path", None) == DB_PATH:
            return conn
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
        _tl.conn = None

    with _conn_lock:
        # One-time, transparent upgrade: an older plaintext memory.db is
        # encrypted in place (backup + atomic swap) before we open it.
        # Guard with _conn_lock so only one thread runs the migration.
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Set NoCoW on the state directory so memory.db and events.db inherit
        # the +C attribute on btrfs.  Best-effort: swallows all failures on
        # non-btrfs filesystems (ext4, xfs, tmpfs, CI).
        _ensure_nocow_dir(STATE_DIR)
        from axi import db_migrate
        db_migrate.migrate_to_encrypted()

    key = load_key()
    c = _open_new_connection(key)

    try:
        DB_PATH.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass

    _tl.conn = c
    _tl.conn_path = DB_PATH
    return c


def _connect_events() -> sqlcipher3.Connection:
    """Return the calling thread's connection to the separate events.db.

    Mirrors :func:`_connect` (thread-local, SQLCipher, WAL, busy_timeout) but
    targets :func:`_events_db_path`. Events are disposable telemetry: on
    corruption we simply rebuild an empty schema rather than running the
    data-precious recovery ladder used for memory.db.
    """
    conn = getattr(_tl, "events_conn", None)
    if conn is not None:
        return conn

    key = load_key()
    path = _events_db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        c = _try_open(path, key)
        if c is None:
            c = sqlcipher3.connect(str(path), isolation_level=None)
            c.execute(f"PRAGMA key = \"x'{key}'\"")
    except sqlcipher3.dbapi2.DatabaseError as exc:
        # Telemetry is disposable — reset rather than recover.
        log.warning("events.db corrupt on open (%s) — rebuilding empty", exc)
        path.unlink(missing_ok=True)
        _remove_wal_sidecars(path)
        c = sqlcipher3.connect(str(path), isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")

    # Rollback-journal, not WAL — events.db is also written by multiple
    # processes (the events writer + brain_metrics from the dashboard). Same
    # cross-process WAL race as memory.db; same fix.
    c.execute("PRAGMA journal_mode=TRUNCATE")
    c.execute("PRAGMA synchronous=NORMAL")
    c.execute("PRAGMA busy_timeout=5000")
    c.row_factory = sqlcipher3.Row
    c.executescript(_EVENTS_SCHEMA)

    _tl.events_conn = c
    _migrate_events_from_memory_db(c)
    return c


def _migrate_events_from_memory_db(events_conn: sqlcipher3.Connection) -> None:
    """One-time copy of legacy events from memory.db into events.db.

    Idempotent by data state: runs only while events.db is empty. After copying,
    legacy rows are deleted from memory.db so it is no longer an events writer
    and cannot re-seed a duplicate migration. Failures are swallowed — telemetry
    history is never worth aborting startup for.
    """
    with _events_migrate_lock:
        try:
            already = events_conn.execute("SELECT count(*) FROM events").fetchone()[0]
            if already:
                return
            if not DB_PATH.exists():
                return
            src = _connect()
            has_tbl = src.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='events'"
            ).fetchone()
            if not has_tbl:
                return
            rows = src.execute(
                "SELECT ts, source, level, message, data_json FROM events"
            ).fetchall()
            if not rows:
                return
            events_conn.executemany(
                "INSERT INTO events(ts, source, level, message, data_json) "
                "VALUES (?, ?, ?, ?, ?)",
                [(r["ts"], r["source"], r["level"], r["message"], r["data_json"]) for r in rows],
            )
            src.execute("DELETE FROM events")
            log.info("migrated %d legacy events memory.db → events.db", len(rows))
        except Exception as exc:  # noqa: BLE001 — telemetry migration must never abort startup
            log.warning("events migration skipped: %s", exc)


@contextmanager
def _tx_events() -> Iterator[sqlcipher3.Connection]:
    """Begin/commit a transaction on the calling thread's events.db connection."""
    c = _connect_events()
    c.execute("BEGIN")
    try:
        yield c
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise


def init_db() -> None:
    with _init_lock:
        c = _connect()
        # Single-writer guard: schema/migration writes must run ONLY on the sole
        # writer (the daemon). A non-owner running executescript/migrations under
        # single_writer opens a concurrent-write window against memory.db. When
        # routing is on and this process is not the owner, just open the
        # connection (schema is already present, materialized by the owner) and
        # skip every write-migration below. No-op when routing is off.
        try:
            from axi import write_router  # lazy: write_router imports store

            if write_router.single_writer_enabled() and not write_router.is_owner():
                log.info(
                    "init_db: single_writer non-owner — skipping schema/migration "
                    "writes (owner materializes the schema)"
                )
                _connect_events()
                return
        except Exception:  # noqa: BLE001 — guard is best-effort, fall through to init
            pass
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
        # M0: devices table (mobile pairing — bearer-token auth, design D5).
        _create_devices_table(c)
        # PoP hardening: pubkey_proven column for pre-existing DBs (no-op on
        # a fresh DB — CREATE TABLE above already has the column).
        migrate_devices_pubkey_proven()
        # Sync-over-vpn schema slice 3a: uuid/lamport/origin_node/deleted_at
        # columns on nodes/edges for pre-existing DBs (no-op on a fresh DB —
        # CREATE TABLE above already has them). Additive only, unread so far.
        migrate_nodes_edges_sync_columns()
        # Sync-over-vpn schema slice PR5 "Expand": edges.src_uuid/dst_uuid/
        # updated_at/relation for pre-existing DBs. UNLIKE the two migrations
        # above, this one is NOT a no-op on a fresh DB either: _SCHEMA's
        # `edges` CREATE TABLE now carries these four columns (matching the
        # PR4 pattern), so on a fresh DB this call's ALTER-TABLE branches are
        # skipped (columns already exist) but its BACKFILL loop still runs —
        # a fresh DB starts with zero rows, so that backfill is a genuine
        # no-op there too, just for a different reason (nothing to backfill,
        # not "column already right"). `nodes.occurred_at` is handled by the
        # separate, pre-existing migrate_nodes_occurred_at() below.
        # Written by every edge-insert path from here on. The uuid endpoints
        # are what the readers resolve through (PR6) and, after the rebuild
        # eleven lines below, the ONLY endpoint representation there is: PR8
        # drops the rowid columns this migration backfills FROM, so on an
        # already-rebuilt database its backfill loop finds no `from_id` and
        # correctly does nothing.
        migrate_edge_endpoint_uuids()
        # Event-date column: stores the real event timestamp (vs. insertion time).
        migrate_nodes_occurred_at()
        # Sync-over-vpn PR8 — THE POINT OF NO RETURN. Rebuilds nodes/edges to
        # mobile's exact DDL and drops from_id/to_id/kind. Runs LAST of the
        # graph migrations because it consumes what they produce (every row
        # needs its uuid and both endpoint uuids before the NOT NULLs bite).
        # Gated by PRAGMA user_version, so this is a no-op on every startup
        # after the first, and it refuses to begin without a snapshot it has
        # proven restorable — that snapshot is the only rollback there is.
        migrate_rebuild_graph_tables()
        # Link-health report. After the rebuild there is no ON DELETE CASCADE
        # and no FK on the endpoints: referential integrity is the
        # application's job now, and this is the only thing that looks. It was
        # written for task 7.14 and, until here, had no production caller at
        # all — a check that satisfies its own tests and never runs.
        #
        # Findings NEVER block startup: a dangling endpoint is legal (an edge
        # may sync before its node) and refusing to boot over one would turn
        # normal sync ordering into an outage.
        #
        # Neither does a FAILING check, and that is the deliberate part. The
        # rule elsewhere in this file is that a check which cannot run must
        # raise — but PR8 nearly shipped exactly that shape here:
        # verify_edge_endpoint_convergence raises on "cannot run" and is
        # called from startup, so a stale join would have left the daemon
        # refusing to start on a database with no way back. That guard
        # protects a corruption invariant and is worth the risk. This one
        # reports link health. Losing the report is bad; losing the daemon
        # because the report broke is worse, so it is logged at ERROR and
        # startup continues.
        # Summarised, not enumerated. Measured on a realistic graph (8k nodes,
        # 20k edges): one line per finding produced 2226 ERROR lines at
        # startup, which does not inform anyone — it buries every other error
        # in the log. The count is the actionable part; a handful of examples
        # is enough to start looking.
        try:
            _dangling = report_dangling_edges(c)
            if _dangling:
                log.error(
                    "init_db: %d edge(s) point at a node that is missing or "
                    "deleted. Legal per the sync design (an edge may arrive "
                    "before its node), so startup continues — but an endpoint "
                    "that never arrives is a permanently broken link. First %d: %s",
                    len(_dangling), min(5, len(_dangling)), "; ".join(_dangling[:5]),
                )
        except Exception as _dangling_exc:  # noqa: BLE001
            log.error(
                "init_db: the dangling-edge report could not run (%s); startup "
                "continues, but nothing is watching link integrity until this "
                "is fixed", _dangling_exc,
            )
        # The pre-rebuild snapshot is never deleted automatically — it is the
        # only rollback past PR8 — so the user has to be TOLD it is there and
        # told when removing it is safe. Reported at every startup while the
        # file exists: it is a standing cost (measured 2.7x on a realistic
        # graph) and a decision only the owner can make. Same failure contract
        # as the dangling-edge report above: loud, never fatal.
        try:
            for _snap in report_pre_rebuild_snapshots():
                _snap_msg = (
                    f"A pre-rebuild backup of your memory database is on disk: "
                    f"{_snap['path']} ({_snap['bytes'] / 1_048_576:.1f} MB, next "
                    f"to a live database of {_snap['live_db_bytes'] / 1_048_576:.1f} MB). "
                    f"It was taken automatically before the sync-schema rebuild "
                    f"and is the ONLY way back to the old schema. Keep it until "
                    f"you have used the graph and confirmed your memories, "
                    f"searches and timeline are all there; after that it is safe "
                    f"to delete this file to reclaim the space. Nothing deletes "
                    f"it for you."
                )
                log.warning("init_db: %s", _snap_msg)
                try:
                    _events.log_warning("store.migration", _snap_msg, dict(_snap))
                except Exception:  # noqa: BLE001 — events must never abort startup
                    pass
        except Exception as _snap_exc:  # noqa: BLE001
            log.error(
                "init_db: the pre-rebuild snapshot report could not run (%s); "
                "startup continues, but if a snapshot exists nothing is telling "
                "you about the disk it is holding", _snap_exc,
            )
        # Conversation source ('chat' | 'voice') so the chat view can hide voice.
        migrate_conversations_source()
        # Events live in their own DB (telemetry isolated from user memory).
        # Open it here so the schema exists and any legacy events are migrated
        # at startup rather than lazily on the first write.
        _connect_events()


def checkpoint() -> None:
    """Flush the WAL into the main DB file. Non-fatal: logs and swallows errors."""
    try:
        # PASSIVE never needs the exclusive lock, avoiding "WAL reset was not
        # sufficient" errors during multi-reader recovery.
        _connect().execute("PRAGMA wal_checkpoint(PASSIVE)")
    except Exception as e:  # noqa: BLE001
        log.warning("wal_checkpoint failed: %s", e)
        try:
            _events.log_warning(
                "store.checkpoint",
                f"WAL checkpoint failed: {e}",
                {"error": str(e)},
            )
        except Exception:  # noqa: BLE001 — events must never abort checkpoint
            pass


# ─────────────────────────── single-writer tripwire ─────────────────────────
#
# Observability only: when single_writer routing is ON and THIS process is not
# the sole writer, a direct memory.db write means either an UNROUTED path (a bug
# to fix — a write helper that skipped maybe_forward) or a degraded writer-down
# fallback. We log it loudly with the call site so missed paths surface at
# runtime. We NEVER block or change the write — the fallback must stay functional.
#
# Throttled by call-site signature so each unique unrouted site logs at most once
# per process run, avoiding log spam on hot paths.
_TRIPWIRE_SEEN: set[tuple[str, ...]] = set()


def _single_writer_tripwire() -> None:
    """Log/emit once per unique call site when a non-owner writes directly.

    No-op (single cheap config read short-circuits) when single_writer is off,
    which is the common case. Never raises.
    """
    try:
        from axi import write_router  # lazy: write_router imports store

        if not write_router.single_writer_enabled() or write_router.is_owner():
            return
        # Frames: [-1] is this helper, [-2] is _tx, so the real call site is the
        # frames above _tx. Build a dedupe signature from the top 3 caller frames.
        stack = traceback.extract_stack(limit=8)
        caller = stack[:-2]  # drop this helper + _tx
        signature = tuple(f"{fr.filename}:{fr.name}:{fr.lineno}" for fr in caller[-3:])
        if signature in _TRIPWIRE_SEEN:
            return
        _TRIPWIRE_SEEN.add(signature)
        where = " <- ".join(
            f"{Path(fr.filename).name}:{fr.name}:{fr.lineno}" for fr in caller[-3:]
        )
        msg = (
            "single_writer: DIRECT memory.db write from non-owner process "
            "(unrouted path or writer-down fallback)"
        )
        log.warning("%s | call site: %s", msg, where)
        _emit_recovery_event("warning", msg, {"call_site": where})
    except Exception:  # noqa: BLE001 — tripwire is best-effort, never break a write
        pass


@contextmanager
def _tx() -> Iterator[sqlite3.Connection]:
    """Begin/commit a transaction on the calling thread's own connection.

    No shared lock needed — each thread has its own connection object.
    SQLite WAL + busy_timeout handle cross-thread write serialization.
    """
    _single_writer_tripwire()
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
    occurred_at: float | None = None,
) -> int:
    """Insert a node, mirror text into FTS, return its id.

    Args:
        kind:       Node kind ('fact', 'person', 'event', …).
        label:      Short human-readable description.
        data:       Optional JSON-serialisable dict of extra properties.
        domain:     Domain key ('health', 'finance', …) or None.
        occurred_at: Real event timestamp (Unix epoch UTC). NULL when the
                     event date is unknown (conversation nodes, etc.). Stored
                     separately from created_at (graph-insertion time) so
                     linkers can group by the actual event day rather than the
                     day data was backfilled into the graph.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("add_node", {
        "kind": kind,
        "label": label,
        "data": data,
        "domain": domain,
        "occurred_at": occurred_at,
    })
    if routed:
        return _res
    now = time.time()
    payload = json.dumps(data or {}, ensure_ascii=False)
    tz = _current_tz()
    with _tx() as c:
        cur = c.execute(
            # `uuid` is assigned HERE, not left to the startup backfill in
            # migrate_nodes_edges_sync_columns(). A node inserted without one
            # stays NULL until the next restart, and every edge created against
            # it in the meantime writes a NULL src_uuid. Every read resolves
            # edges through src_uuid (PR6), so such a NULL is a link missing
            # from the user's own memory graph — which is why the endpoint
            # uuids are NOT NULL in the rebuilt table and why
            # verify_edge_endpoint_convergence() raises on a NULL endpoint
            # rather than reading it as "converged".
            "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, created_tz, occurred_at, uuid) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (kind, label, payload, domain, now, now, tz, occurred_at, str(uuid.uuid4())),
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
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("add_edge", {
        "from_id": from_id,
        "to_id": to_id,
        "kind": kind,
        "data": data,
    })
    if routed:
        return _res
    payload = json.dumps(data or {}, ensure_ascii=False)
    now = time.time()
    with _tx() as c:
        # PR8: the endpoints ARE the uuids now — `from_id`/`to_id` no longer
        # exist. The caller still passes local rowids because that is what
        # every caller in this codebase holds; they are resolved here, in the
        # SAME transaction as the insert.
        src_uuid, dst_uuid = _require_endpoint_uuids(c, from_id, to_id)
        cur = c.execute(
            # `uuid` is assigned HERE. It used to be left to the startup
            # backfill, which was survivable only while the column was
            # nullable; under mobile's `uuid NOT NULL UNIQUE` an edge written
            # without one does not exist at all.
            "INSERT INTO edges(uuid, src_uuid, dst_uuid, relation, data, "
            "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (str(uuid.uuid4()), src_uuid, dst_uuid, kind, payload, now, now),
        )
        return cur.lastrowid


def _require_endpoint_uuids(conn, from_id: int, to_id: int) -> tuple[str, str]:
    """Resolve two node rowids to their uuids, or raise naming the culprit.

    Before PR8 a missing node quietly produced a NULL endpoint: an edge that
    every uuid-resolving read then skipped, so the relation simply was not
    there — indistinguishable from lost data. `src_uuid NOT NULL` makes that
    impossible, and this turns the resulting bare `IntegrityError` into a
    message that says which node id could not be found.
    """
    src_row = conn.execute("SELECT uuid FROM nodes WHERE id = ?", (from_id,)).fetchone()
    dst_row = conn.execute("SELECT uuid FROM nodes WHERE id = ?", (to_id,)).fetchone()
    missing = [
        str(nid) for nid, row in ((from_id, src_row), (to_id, dst_row))
        if row is None or row[0] is None
    ]
    if missing:
        raise ValueError(
            f"cannot create an edge: node id(s) {', '.join(missing)} have no "
            "uuid (missing row?), and an edge endpoint must name a node uuid"
        )
    return src_row[0], dst_row[0]


def delete_node(node_id: int) -> bool:
    """Tombstone a node and everything attached to it.

    PR7 (design-schema.md Decision 3). The node and its edges are MARKED
    deleted (`deleted_at`), not removed: sync cannot replicate an absence — a
    peer that never sees a row cannot tell "deleted" from "not yet received",
    so it hands the memory straight back on the next exchange.

    The `nodes_fts` and `vec_nodes` rows are still HARD-deleted, deliberately.
    Both are local derived state that is never synced, and leaving the FTS row
    behind is the named worst case: the graph would say the memory is gone
    while the search box handed it back. That removal happens in the SAME
    transaction as the tombstone.

    Returns True if a live node row was tombstoned, False otherwise (including
    a second call for an already-tombstoned node).

    SAFETY: refuses to delete the user-hub node (data role=user) — you cannot
    delete "yourself". Returns False in that case without touching anything.

    Defensive: never raises; returns False on bad input or any error.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("delete_node", {"node_id": node_id})
    if routed:
        return _res
    try:
        nid = int(node_id)
    except (TypeError, ValueError):
        return False
    c = _connect()
    row = c.execute(
        "SELECT data FROM nodes WHERE id = ? AND deleted_at IS NULL", (nid,)
    ).fetchone()
    if row is None:
        return False
    # Hub guard: never delete the user's own anchor node.
    try:
        if json.loads(row["data"] or "{}").get("role") == "user":
            log.warning("delete_node refused: node %d is the user hub", nid)
            return False
    except (ValueError, TypeError):
        pass
    now = time.time()
    try:
        with _tx() as tx:
            # Edges are matched on the sync-stable endpoint uuids, not the
            # rowid pair PR8 drops. Everything below runs in ONE transaction:
            # split in two, a crash in between would leave a live node whose
            # relations had all been tombstoned, or the reverse.
            uuid_row = tx.execute("SELECT uuid FROM nodes WHERE id = ?", (nid,)).fetchone()
            node_uuid = uuid_row[0] if uuid_row else None
            tx.execute(
                "UPDATE edges SET deleted_at = ?, updated_at = ? "
                "WHERE (src_uuid = ? OR dst_uuid = ?) AND deleted_at IS NULL",
                (now, now, node_uuid, node_uuid),
            )
            # nodes_fts stays a HARD delete: local derived state, never synced,
            # and the one row that must not outlive the tombstone (7.11).
            tx.execute("DELETE FROM nodes_fts WHERE rowid = ?", (nid,))
            # vec_nodes likewise — hard, best-effort (sqlite-vec may be
            # unloaded). Note this statement is now the ONLY thing cleaning it:
            # trg_nodes_delete_vec is an AFTER DELETE trigger and stops firing
            # the moment the node delete becomes an UPDATE.
            try:
                tx.execute("DELETE FROM vec_nodes WHERE node_id = ?", (nid,))
            except Exception:  # noqa: BLE001
                pass
            cur = tx.execute(
                # updated_at is bumped with deleted_at, matching the edge
                # tombstone above. A tombstone IS a write, and last-writer-wins
                # orders by updated_at: leave it stale and a peer that merely
                # EDITED this node later than its last write beats the delete,
                # handing the user back a memory they deleted. No observable
                # change today — the row is invisible to every read from here
                # on — which is precisely why it is cheap to get right now.
                "UPDATE nodes SET deleted_at = ?, updated_at = ? "
                "WHERE id = ? AND deleted_at IS NULL",
                (now, now, nid),
            )
        return cur.rowcount > 0
    except Exception:  # noqa: BLE001
        log.warning("delete_node failed for %d", nid, exc_info=True)
        return False


def delete_edge(edge_id: int) -> bool:
    """Tombstone one edge by id. Returns True if a LIVE row was tombstoned.

    PR7: marked, not removed, for the same reason as `delete_node`. The
    `AND deleted_at IS NULL` guard is what makes a second call report False
    instead of rewriting the timestamp and claiming success.

    Defensive: never raises; returns False on bad input or any error.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("delete_edge", {"edge_id": edge_id})
    if routed:
        return _res
    try:
        eid = int(edge_id)
    except (TypeError, ValueError):
        return False
    try:
        with _tx() as tx:
            now = time.time()
            cur = tx.execute(
                "UPDATE edges SET deleted_at = ?, updated_at = ? "
                "WHERE id = ? AND deleted_at IS NULL",
                (now, now, eid),
            )
        return cur.rowcount > 0
    except Exception:  # noqa: BLE001
        log.warning("delete_edge failed for %d", eid, exc_info=True)
        return False


def search_nodes_fts(query: str, limit: int = 10) -> list[sqlite3.Row]:
    """FTS5 lexical search over node labels + data text.

    PR7: `deleted_at IS NULL` here is belt AND braces. `delete_node` already
    removes the `nodes_fts` row in the same transaction as the tombstone
    (7.11), so a locally deleted memory cannot reach this join at all. A
    tombstone that arrives from a peer does NOT go through `delete_node`, and
    then this filter is the only thing between it and the search box.
    """
    if not query.strip():
        return []
    c = _connect()
    return list(c.execute(
        "SELECT n.* FROM nodes_fts f "
        "JOIN nodes n ON n.id = f.rowid "
        "WHERE nodes_fts MATCH ? AND n.deleted_at IS NULL "
        "ORDER BY rank LIMIT ?",
        (query, limit),
    ))


def get_node(node_id: int) -> sqlite3.Row | None:
    c = _connect()
    row = c.execute(
        "SELECT * FROM nodes WHERE id = ? AND deleted_at IS NULL", (node_id,)
    ).fetchone()
    return row


def neighbors(node_id: int, edge_kind: str | None = None, depth: int = 1) -> list[sqlite3.Row]:
    """Return nodes connected by outgoing edges; depth=1 for now (V2: recursive CTE).

    Edges are resolved through `src_uuid`/`dst_uuid`, the sync-stable endpoint
    references mobile uses, not through the local `from_id`/`to_id` rowids
    (PR6 — design-schema.md Decision 2 step 2). Rowid 42 on the laptop is not
    rowid 42 on the phone; the uuid is the same on both. This was a
    behaviour-preserving change on any converged database when it landed —
    both representations still existed then — and PR8's rebuild has since
    dropped the rowid columns entirely, so the uuid endpoints are now the
    only ones. A NULL endpoint uuid, the one state where the rewrite would
    have changed behaviour, is made impossible by the insert paths, by the
    rebuilt table's NOT NULL, and loud by
    `verify_edge_endpoint_convergence()`.
    """
    c = _connect()
    if edge_kind:
        rows = c.execute(
            "SELECT n.* FROM nodes n JOIN edges e ON e.dst_uuid = n.uuid "
            "WHERE e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.relation = ? "
            "AND e.deleted_at IS NULL AND n.deleted_at IS NULL",
            (node_id, edge_kind),
        )
    else:
        rows = c.execute(
            "SELECT n.* FROM nodes n JOIN edges e ON e.dst_uuid = n.uuid "
            "WHERE e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.deleted_at IS NULL AND n.deleted_at IS NULL",
            (node_id,),
        )
    return list(rows)


def same_day_neighbors(node_id: int, conn=None) -> list[dict[str, Any]]:
    """Return all nodes connected to node_id via a 'same-day' edge in EITHER direction.

    Uses a UNION of two direction-specific queries so SQLite can use the
    dedicated idx_edges_src and idx_edges_dst indexes instead of a full
    OR-scan.  Self (n.id = node_id) is excluded in both arms.

    Endpoints resolve through `src_uuid`/`dst_uuid` (PR6). The two indexes
    named above replace idx_edges_from/idx_edges_to, which this rewrite
    retires — without them this query would silently become a full scan,
    which is the whole reason it was written as a UNION in the first place.

    Returns a list of node dicts (id, kind, label, domain, created_at,
    occurred_at).  Returns [] on any error.
    """
    c = conn or _connect()
    try:
        rows = c.execute(
            """
            SELECT n.id, n.kind, n.label, n.domain, n.data, n.created_at, n.occurred_at
            FROM nodes n
            JOIN edges e ON e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?)
                        AND e.dst_uuid = n.uuid AND e.relation = 'same-day'
            WHERE n.id != ? AND e.deleted_at IS NULL AND n.deleted_at IS NULL
            UNION
            SELECT n.id, n.kind, n.label, n.domain, n.data, n.created_at, n.occurred_at
            FROM nodes n
            JOIN edges e ON e.dst_uuid = (SELECT uuid FROM nodes WHERE id = ?)
                        AND e.src_uuid = n.uuid AND e.relation = 'same-day'
            WHERE n.id != ? AND e.deleted_at IS NULL AND n.deleted_at IS NULL
            """,
            (node_id, node_id, node_id, node_id),
        ).fetchall()
    except Exception:  # noqa: BLE001
        return []
    return [dict(r) for r in rows]


def find_fact_by_label(label: str, conn=None) -> int | None:
    """Return the id of an existing 'fact' node with this exact label, or None.

    Used by chat fact-extraction to avoid creating exact duplicates: identity /
    preference facts are timeless, so the same label twice is a duplicate, not a
    new event (time-series domain facts carry distinct occurred_at and are
    handled by the domain bridge, not this path).
    """
    label = (label or "").strip()
    if not label:
        return None
    c = conn or _connect()
    try:
        row = c.execute(
            "SELECT id FROM nodes WHERE kind='fact' AND label=? "
            "AND deleted_at IS NULL LIMIT 1", (label,)
        ).fetchone()
    except Exception:  # noqa: BLE001
        return None
    return row["id"] if row else None


def recent_facts(days: int = 2, limit: int = 8, conn=None) -> list[dict[str, Any]]:
    """Return the most recently-occurring 'fact' nodes within the last *days*,
    newest first.

    Used by recall to ALWAYS surface freshly-logged personal data (e.g. today's
    vitals) regardless of semantic similarity: a numeric-only label like
    "110 81 51 pulsos" sits far from a query like "presión", so KNN alone misses
    it. Returns [] on any error.
    """
    c = conn or _connect()
    cutoff = time.time() - max(0, days) * 86400.0
    try:
        rows = c.execute(
            "SELECT id, kind, label, domain, data, created_at, occurred_at FROM nodes "
            "WHERE kind = 'fact' AND deleted_at IS NULL "
            "AND COALESCE(occurred_at, created_at) >= ? "
            "ORDER BY COALESCE(occurred_at, created_at) DESC LIMIT ?",
            (cutoff, int(limit)),
        ).fetchall()
    except Exception:  # noqa: BLE001
        return []
    return [dict(r) for r in rows]


# ─────────────────────────── conversations ─────────────────────────────

def add_conversation(user_text: str, axi_text: str, has_screenshot: bool = False,
                     session_id: str | None = None, source: str = "chat") -> int:
    """Record a turn and return its conversation row id.

    `source` is 'chat' (default) or 'voice'. The dashboard chat history hides
    'voice' turns so spoken conversations don't clutter the typed chat.
    """
    from axi import write_router  # lazy, avoid import cycle
    if write_router.single_writer_enabled() and not write_router.is_owner():
        try:
            return write_router.forward_write("add_conversation", {
                "user_text": user_text,
                "axi_text": axi_text,
                "has_screenshot": has_screenshot,
                "session_id": session_id,
                "source": source,
            })
        except write_router.WriteServerUnavailable:
            pass  # writer down → fall back to a direct local write (degraded)
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, session_id, has_screenshot, source) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (time.time(), user_text, axi_text, session_id, int(has_screenshot), source),
        )
        return cur.lastrowid


def set_conversation_node_id(conv_id: int, node_id: int) -> bool:
    """Bind a conversation row to its graph node (conversations.node_id).

    Routable leaf writer so the dashboard's conversation→node bridge in
    ConversationMemory._add_once goes through the sole writer instead of a raw
    _tx() UPDATE. Returns True if a row was updated.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("set_conversation_node_id", {
        "conv_id": conv_id,
        "node_id": node_id,
    })
    if routed:
        return _res
    with _tx() as c:
        cur = c.execute(
            "UPDATE conversations SET node_id = ? WHERE id = ?", (node_id, conv_id)
        )
        return cur.rowcount > 0


def recent_conversations(limit: int = 20) -> list[sqlite3.Row]:
    """Latest turns, OLDEST FIRST for LLM context order."""
    c = _connect()
    rows = list(c.execute(
        "SELECT * FROM conversations ORDER BY ts DESC LIMIT ?", (limit,)
    ))
    return list(reversed(rows))


def oldest_conversations(limit: int = 200) -> list[sqlite3.Row]:
    """Return the OLDEST *limit* conversation turns (ascending by ts). Used by
    the chat archiver to summarize + prune the tail of the log."""
    c = _connect()
    return list(c.execute(
        "SELECT * FROM conversations ORDER BY ts ASC LIMIT ?", (limit,)
    ))


def delete_conversations(ids: list[int]) -> int:
    """Delete conversation turns by id (batch). Graph nodes are NOT touched —
    durable facts extracted from these turns stay in the graph. Returns count."""
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("delete_conversations", {"ids": ids})
    if routed:
        return _res
    ids = [int(i) for i in ids if i]
    if not ids:
        return 0
    with _tx() as c:
        c.executemany("DELETE FROM conversations WHERE id = ?", [(i,) for i in ids])
    return len(ids)


def clear_conversations() -> int:
    """Wipe chat history. Does NOT touch graph nodes — those are long-term."""
    with _tx() as c:
        cur = c.execute("SELECT COUNT(*) AS n FROM conversations")
        n = cur.fetchone()["n"]
        c.execute("DELETE FROM conversations")
        return n


def delete_conversation(conv_id: int) -> bool:
    """Delete a single conversation turn (the user message AND Axi's reply — one
    row). Returns True if a row was removed. Graph nodes are left untouched."""
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("delete_conversation", {"conv_id": conv_id})
    if routed:
        return _res
    with _tx() as c:
        cur = c.execute("DELETE FROM conversations WHERE id = ?", (int(conv_id),))
        return cur.rowcount > 0


def conversation_count() -> int:
    c = _connect()
    return c.execute("SELECT COUNT(*) AS n FROM conversations").fetchone()["n"]


def attachments_dir() -> Path:
    """Directory for chat attachment files. Derived from DB_PATH.parent so it
    follows test monkeypatching (same trick as events_db_path)."""
    d = DB_PATH.parent / "attachments"
    d.mkdir(parents=True, exist_ok=True)
    return d


def add_attachment(
    *,
    kind: str,
    filename: str,
    mime: str,
    orig_name: str | None,
    sha256: str | None,
    size_bytes: int,
    session_id: str | None = None,
) -> int:
    """Insert a new attachment row (conv_id is NULL until link_attachments is called).

    Returns the new row id.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("add_attachment", {
        "kind": kind,
        "filename": filename,
        "mime": mime,
        "orig_name": orig_name,
        "sha256": sha256,
        "size_bytes": size_bytes,
        "session_id": session_id,
    })
    if routed:
        return _res
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO chat_attachments"
            "(kind, filename, mime, orig_name, sha256, size_bytes, session_id, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (kind, filename, mime, orig_name, sha256, size_bytes, session_id, time.time()),
        )
        return cur.lastrowid


def link_attachments(conv_id: int, attachment_ids: list[int]) -> None:
    """Bind a list of attachment rows to a conversation turn.

    Only claims rows that are still unlinked (conv_id IS NULL) to prevent
    accidental re-linking across conversations.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("link_attachments", {
        "conv_id": conv_id,
        "attachment_ids": attachment_ids,
    })
    if routed:
        return _res
    if not attachment_ids:
        return
    with _tx() as c:
        for att_id in attachment_ids:
            c.execute(
                "UPDATE chat_attachments SET conv_id = ? WHERE id = ? AND conv_id IS NULL",
                (conv_id, att_id),
            )


def get_attachment(att_id: int) -> sqlite3.Row | None:
    """Fetch a single attachment row by id. Returns None if not found."""
    c = _connect()
    return c.execute(
        "SELECT * FROM chat_attachments WHERE id = ?", (att_id,)
    ).fetchone()


def delete_attachment(att_id: int) -> sqlite3.Row | None:
    """Delete an attachment row and return the row that was deleted (for file cleanup).

    Returns None if the row did not exist.

    Note: when routed to the sole writer the result is a plain dict (a
    sqlite3.Row is not JSON-serialisable); callers only index it (row["filename"]),
    which works the same on a dict.
    """
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("delete_attachment", {"att_id": att_id})
    if routed:
        return _res
    row = get_attachment(att_id)
    if row is None:
        return None
    with _tx() as c:
        c.execute("DELETE FROM chat_attachments WHERE id = ?", (att_id,))
    return row


def list_attachments_for_convs(conv_ids: list[int]) -> dict[int, list[sqlite3.Row]]:
    """Return attachment rows grouped by conversation id.

    The result is a dict keyed by conv_id. Conversations with no attachments
    do not appear in the dict. Returns {} for empty input.
    """
    if not conv_ids:
        return {}
    placeholders = ",".join("?" * len(conv_ids))
    c = _connect()
    rows = c.execute(
        f"SELECT * FROM chat_attachments WHERE conv_id IN ({placeholders}) ORDER BY id",
        conv_ids,
    ).fetchall()
    result: dict[int, list[sqlite3.Row]] = {}
    for row in rows:
        cid = row["conv_id"]
        result.setdefault(cid, []).append(row)
    return result


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
    with _tx_events() as c:
        c.execute(
            "INSERT INTO events(ts, source, level, message, data_json) "
            "VALUES (?, ?, ?, ?, ?)",
            (ts, source, level, message, data_json),
        )


def trim_events(keep: int = 5000) -> None:
    """Keep only the most recent `keep` event rows (delete older)."""
    with _tx_events() as c:
        c.execute(
            "DELETE FROM events WHERE id NOT IN ("
            "  SELECT id FROM events ORDER BY ts DESC LIMIT ?"
            ")",
            (keep,),
        )


def query_events(
    source: str | None = None,
    since_ts: float | None = None,
    level: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Query the persistent events table with optional filters.

    Returns a list of event dicts ordered newest-first.  Reads from the
    SQLite table directly (not the in-memory ring buffer), so it can return
    the full persisted history beyond the 200-event ring cap.

    Args:
        source:   Filter to events whose ``source`` matches exactly.
        since_ts: Unix epoch float — include only events with ``ts > since_ts``.
        level:    Filter to events whose ``level`` matches exactly.
        limit:    Maximum number of rows to return (default 100).
        offset:   Skip this many rows (for pagination, default 0).

    Returns:
        List of dicts with keys: ts, source, level, message, data.
    """
    # Clamp limit and offset defensively to safe ranges.
    limit = max(1, min(limit, 5000))
    offset = max(0, offset)

    clauses: list[str] = []
    params: list[Any] = []

    if source is not None:
        clauses.append("source = ?")
        params.append(source)
    if level is not None:
        clauses.append("level = ?")
        params.append(level)
    if since_ts is not None:
        clauses.append("ts > ?")
        params.append(since_ts)

    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    params.extend([limit, offset])

    sql = (
        f"SELECT ts, source, level, message, data_json "  # noqa: S608
        f"FROM events {where} "
        f"ORDER BY ts DESC "
        f"LIMIT ? OFFSET ?"
    )

    c = _connect_events()
    rows = c.execute(sql, params).fetchall()

    result: list[dict[str, Any]] = []
    for row in rows:
        data: dict[str, Any] | None = None
        if row["data_json"]:
            try:
                data = json.loads(row["data_json"])
            except (TypeError, ValueError):
                data = None
        result.append({
            "ts": row["ts"],
            "source": row["source"],
            "level": row["level"],
            "message": row["message"],
            "data": data,
        })
    return result


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
    """Persist one brain call metric row. Called from a background thread.

    Writes to events.db (disposable telemetry), NOT memory.db, so brain-call
    metric writes never contend for the memory.db WAL write lock across the
    dashboard and daemon processes.
    """
    with _tx_events() as c:
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
    """Most recent brain metrics as dicts, newest first. Reads events.db."""
    c = _connect_events()
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
    """Keep only the most recent `keep` brain metric rows. Trims events.db."""
    with _tx_events() as c:
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


def migrate_conversations_source() -> None:
    """Idempotent: add a `source` column to conversations ('chat' | 'voice') so
    the dashboard chat history can hide spoken (voice) turns.

    Existing rows keep NULL — the chat query treats NULL as 'chat' (shown),
    because we cannot retroactively tell whether an old turn was voice or typed,
    and silently hiding real history would be worse than showing it.
    """
    c = _connect()
    existing = {r[1] for r in c.execute("PRAGMA table_info(conversations)").fetchall()}
    if "source" not in existing:
        c.execute("ALTER TABLE conversations ADD COLUMN source TEXT")


def migrate_nodes_occurred_at() -> None:
    """Idempotent migration: add occurred_at column to the nodes table.

    occurred_at stores the real event moment (Unix epoch UTC) — the timestamp
    of the domain entry this node represents. It is NULL for nodes created
    without a source entry (e.g. conversation nodes, person nodes).

    Linkers use COALESCE(occurred_at, created_at) so existing nodes without
    an event date fall back to the insertion timestamp (backward-compatible).

    Safe to call multiple times (guarded by PRAGMA table_info).
    """
    c = _connect()
    existing = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    if "occurred_at" not in existing:
        c.execute("ALTER TABLE nodes ADD COLUMN occurred_at REAL")
        c.execute(
            "CREATE INDEX IF NOT EXISTS idx_nodes_occurred ON nodes(occurred_at)"
        )


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


def knn_nodes_scored(conn, *, vector: list[float], k: int = 10) -> list[tuple[int, float]]:
    """Return the k nearest node ids with their cosine DISTANCE from vec_nodes.

    Delegates to knn_nodes_with_distance (which already exists further below).
    Returns a list of (node_id, distance) tuples ordered by ascending distance.
    Returns an empty list if vec_nodes is empty or sqlite-vec is not loaded.
    """
    return knn_nodes_with_distance(conn, vector=vector, k=k)


def knn_nodes(conn, *, vector: list[float], k: int = 10) -> list[int]:
    """Return the k nearest node ids from vec_nodes ordered by cosine distance.

    Returns an empty list if vec_nodes is empty or sqlite-vec is not loaded.
    Delegates to knn_nodes_scored to avoid duplicated KNN logic.
    """
    return [nid for nid, _dist in knn_nodes_scored(conn, vector=vector, k=k)]


# ─────────────────── embed worker (Slice 1) ──────────────────────────────────

# Re-export embed_text from embed_client so store.py callers use a single import,
# and tests can patch "axi.store.embed_text" cleanly.
def embed_text(text: str, *, mode: str = "passage", timeout: float | None = None) -> list[float]:
    """Thin wrapper around embed_client.embed — patchable in tests.

    Args:
        text: Text to embed.
        mode: 'query' or 'passage' (passed to embed_client).
        timeout: Optional HTTP timeout override. None uses embed_client default (30 s).
    """
    from axi.embed_client import embed

    kwargs: dict = {"mode": mode}  # type: ignore[arg-type]
    if timeout is not None:
        kwargs["timeout"] = timeout
    return embed(text, **kwargs)


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
        "AND deleted_at IS NULL "
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
_embed_worker_stop = threading.Event()   # sentinel: set → worker loop exits
_embed_worker_thread: threading.Thread | None = None


def _embed_worker_loop() -> None:
    """Single consumer thread: drain embed_pending_nodes whenever signalled.

    Blocks on the queue (1 s timeout so the thread wakes periodically).
    On EmbedServiceError: backs off 10 s; nodes remain embedding IS NULL and
    will be retried on the next drain cycle (service-down safe, no lost nodes).
    Exits cleanly when _embed_worker_stop is set (for test teardown / shutdown).
    """
    _BACKOFF_S = 10.0
    _DRAIN_LIMIT = 50  # nodes per drain cycle

    while not _embed_worker_stop.is_set():
        try:
            _EMBED_QUEUE.get(timeout=1.0)
            if _embed_worker_stop.is_set():
                return
            # Drain the queue so we don't process one-at-a-time when bursting.
            while not _EMBED_QUEUE.empty():
                try:
                    _EMBED_QUEUE.get_nowait()
                except queue.Empty:
                    break
        except queue.Empty:
            continue

        if _embed_worker_stop.is_set():
            return

        try:
            embed_pending_nodes(limit=_DRAIN_LIMIT)
        except Exception:  # noqa: BLE001
            log.debug("embed_worker: drain error — backing off %ss", _BACKOFF_S)
            # Use .wait() instead of time.sleep() so the stop event can interrupt
            # the backoff immediately, enabling fast shutdown/test teardown.
            _embed_worker_stop.wait(_BACKOFF_S)


def _ensure_embed_worker() -> None:
    """Start the shared embed consumer thread if it has not been started yet.

    Gated by _EMBED_WRITER_ENABLED: only the daemon process opts in via
    enable_embed_writer().  This prevents embed worker threads — which write
    memory.db — from starting in the dashboard or any other reader process.
    """
    if not _EMBED_WRITER_ENABLED:
        return
    global _embed_worker_thread
    if _embed_worker_started.is_set():
        return
    with _embed_worker_lock:
        if _embed_worker_started.is_set():
            return
        _embed_worker_stop.clear()
        t = threading.Thread(target=_embed_worker_loop, name="axi-embed-worker", daemon=True)
        t.start()
        _embed_worker_thread = t
        _embed_worker_started.set()


def stop_embed_worker(timeout: float = 3.0) -> None:
    """Signal the embed worker to stop and wait for it to exit.

    Safe to call even if the worker was never started.  Used in test teardown
    to prevent the daemon thread from touching sqlcipher during interpreter
    shutdown (which causes SIGSEGV).

    Reaps ALL threads named "axi-embed-worker" (not only the currently tracked
    one) so orphaned workers — spawned when _embed_worker_started was cleared
    while a prior worker was still alive — are also joined within `timeout`.
    """
    global _embed_worker_thread
    _embed_worker_stop.set()
    # Unblock a waiting get() by draining and sending a dummy signal.
    try:
        _EMBED_QUEUE.put_nowait(-1)
    except queue.Full:
        pass
    # Collect every live thread named axi-embed-worker (handles orphans too).
    workers = [
        t for t in threading.enumerate()
        if t.name == "axi-embed-worker" and t.is_alive()
    ]
    # Distribute the overall timeout budget across all workers.
    deadline = time.monotonic() + timeout
    for t in workers:
        remaining = max(0.0, deadline - time.monotonic())
        t.join(timeout=remaining)
    # Reset state so _ensure_embed_worker() can restart a fresh worker later.
    _embed_worker_stop.clear()
    _embed_worker_started.clear()
    _embed_worker_thread = None


def trigger_embed_for_node(node_id: int) -> None:
    """Signal the shared background embed worker that a new node is pending.

    Returns immediately — never blocks fact creation.  The worker thread
    drains embed_pending_nodes(limit=50) in batches.  If the embed service is
    down, nodes stay embedding IS NULL and are retried on the next signal.

    Gated by AXI_DISABLE_BG_WORKERS: when set, the implicit auto-start is
    suppressed so test isolation is preserved (no TOCTOU race on DB_PATH).
    """
    if not _BG_WORKERS_DISABLED:
        _ensure_embed_worker()
    try:
        _EMBED_QUEUE.put_nowait(node_id)
    except queue.Full:
        # Queue already full — a drain is already scheduled; nothing is lost
        # because embed_pending_nodes selects ALL embedding IS NULL nodes.
        pass


def run_periodic_embed_drain(
    *,
    embed_limit: int = 50,
    similarity_threshold: float = 0.85,
    backfill_node_limit: int = 50,
    backfill_days: int = 7,
) -> None:
    """Ingest new domain facts, drain pending embeddings, backfill similar-to
    edges, and run auto-linkers.

    Intended to be called periodically (e.g. every 5 minutes) from the dashboard
    lifespan background task.  All operations are idempotent and bounded.

    Domain ingestion runs FIRST so that freshly logged entries (health, finance,
    relationships, …) become graph fact-nodes and get embedded + linked within
    the same drain cycle. It is bounded by *backfill_node_limit* (new nodes per
    tick) and *backfill_days* (look-back window); already-bridged entries are
    skipped, so the backlog drains over successive ticks. The manual
    ``backfill.py`` CLI still covers deep historical (older than backfill_days)
    ingestion.

    row_factory is set to sqlcipher3.Row before run_auto_linkers so the linker
    dict-access (row["col"]) works correctly regardless of caller state.
    """
    try:
        from axi.domain_bridge import backfill_all_domains
        backfill_all_domains(days=backfill_days, node_limit=backfill_node_limit)
    except Exception as _e:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: backfill_all_domains failed", exc_info=True)
        try:
            from axi import events as _events
            _events.log_warning(
                "embed.drain",
                f"backfill_all_domains failed: {_e}",
                {"step": "backfill_all_domains", "error": str(_e)},
            )
        except Exception:  # noqa: BLE001
            pass

    try:
        embed_pending_nodes(limit=embed_limit)
    except Exception as _e:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: embed_pending_nodes failed", exc_info=True)
        try:
            from axi import events as _events
            _events.log_warning(
                "embed.drain",
                f"embed_pending_nodes failed: {_e}",
                {"step": "embed_pending_nodes", "error": str(_e)},
            )
        except Exception:  # noqa: BLE001
            pass

    try:
        backfill_similar_to_edges(threshold=similarity_threshold)
    except Exception as _e:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: backfill_similar_to_edges failed", exc_info=True)
        try:
            from axi import events as _events
            _events.log_warning(
                "embed.drain",
                f"backfill_similar_to_edges failed: {_e}",
                {"step": "backfill_similar_to_edges", "error": str(_e)},
            )
        except Exception:  # noqa: BLE001
            pass

    try:
        from axi.linkers import run_auto_linkers
        from axi import config as _cfg
        c = _connect()
        # Ensure row_factory is set so linkers can use row["col"] access.
        import sqlcipher3 as _sc3
        c.row_factory = _sc3.Row
        _tz = str(_cfg.get("timezone", "UTC"))
        run_auto_linkers(c, tz_name=_tz)
    except Exception as _e:  # noqa: BLE001
        log.warning("run_periodic_embed_drain: run_auto_linkers failed", exc_info=True)
        try:
            from axi import events as _events
            _events.log_warning(
                "embed.drain",
                f"run_auto_linkers failed: {_e}",
                {"step": "run_auto_linkers", "error": str(_e)},
            )
        except Exception:  # noqa: BLE001
            pass


# ─────────────────── semantic search (Slice 1) ───────────────────────────────


def semantic_search_nodes(
    query: str,
    *,
    k: int = 20,
    conn=None,
    timeout: float | None = None,
) -> list[dict[str, Any]]:
    """Embed *query* and return nodes ranked by cosine similarity via vec_nodes KNN.

    Each returned dict includes: id, kind, label, domain, created_at,
    occurred_at (float|None), and distance (float, cosine distance from query).

    Returns an empty list if:
      - The embed service is down or times out (EmbedServiceError / TimeoutError).
      - vec_nodes is empty or not loaded.

    Args:
        query: Text to embed for similarity search.
        k: Number of nearest neighbours to retrieve.
        conn: Optional connection (injected in tests).
        timeout: Optional HTTP timeout for the embed call. None uses the embed
            client default (30 s). Pass a short value (e.g. 2.0) from
            build_recall_block so a slow embed cannot stall the user's turn.

    Never raises — callers receive an empty list on any failure.
    """
    from axi.embed_client import EmbedServiceError

    try:
        vector = embed_text(query, mode="query", timeout=timeout)
    except EmbedServiceError:
        log.debug("semantic_search_nodes: embed service down for query %r", query)
        return []
    except Exception as exc:  # noqa: BLE001
        log.warning("semantic_search_nodes: unexpected embed error: %s", exc)
        return []

    c = conn or _connect()

    try:
        scored = knn_nodes_scored(c, vector=vector, k=k)
    except Exception as exc:  # noqa: BLE001
        log.debug("semantic_search_nodes: knn failed: %s", exc)
        return []

    if not scored:
        return []

    node_ids = [nid for nid, _dist in scored]
    id_to_distance = {nid: dist for nid, dist in scored}

    # Fetch node metadata in one query, preserving KNN order.
    placeholders = ",".join("?" * len(node_ids))
    rows = c.execute(
        f"SELECT id, kind, label, domain, data, created_at, occurred_at FROM nodes "
        f"WHERE id IN ({placeholders}) AND deleted_at IS NULL",
        node_ids,
    ).fetchall()

    # Re-order by the KNN rank and attach distance.
    id_to_row: dict[int, dict[str, Any]] = {}
    for r in rows:
        row = dict(r)
        nid = int(row["id"])
        row["distance"] = id_to_distance.get(nid, 1.0)
        id_to_row[nid] = row

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
    from axi import write_router  # lazy, avoid import cycle
    routed, _res = write_router.maybe_forward("upsert_domain_node_map", {
        "domain": domain,
        "entry_id": entry_id,
        "node_id": node_id,
    })
    if routed:
        return _res
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


# ──────────────────── devices (mobile pairing, M0 — design D5) ──────────────
#
# Paired phones/tablets authenticate with a per-device bearer token, shown
# once at pairing time. Only the SHA-256 hash of that token is ever
# persisted here — device_get_by_token_hash is the auth middleware's lookup
# call site (wired in a later M0 task). Purely additive: this table has no
# foreign keys into the graph and no existing table/column is touched.


def _create_devices_table(conn) -> None:
    """Create the devices table if it does not exist.

    Called from init_db() so every fresh DB has the table from the start
    (mirrors the domain_node_map bootstrap-table precedent above).
    """
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS devices (
            device_id      TEXT PRIMARY KEY,
            name           TEXT NOT NULL,
            token_hash     TEXT NOT NULL UNIQUE,
            device_pubkey  TEXT,
            pubkey_proven  INTEGER NOT NULL DEFAULT 0,
            created_at     REAL NOT NULL,
            last_seen_at   REAL,
            revoked_at     REAL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_devices_token_hash ON devices(token_hash)"
    )


def migrate_devices_pubkey_proven() -> None:
    """Idempotent migration: add `pubkey_proven` to a pre-existing `devices`
    table (proof-of-possession hardening, spec `mesh-trust-hardening`).

    A fresh DB already has the column via `_create_devices_table`'s
    `CREATE TABLE IF NOT EXISTS` — this only fires for a DB created BEFORE
    this change. `ALTER TABLE ... DEFAULT 0` backfills every EXISTING row to
    0 in the same statement (SQLite applies the column default to all rows),
    which is exactly the migration's contract: a pre-change stored
    `device_pubkey` was never proven, so it MUST be recorded unproven — any
    future sealed-box consumer treats it as absent until re-pair (see
    `device_sealing_pubkey`). Safe to call multiple times.
    """
    c = _connect()
    existing = {r[1] for r in c.execute("PRAGMA table_info(devices)").fetchall()}
    if "pubkey_proven" not in existing:
        c.execute(
            "ALTER TABLE devices ADD COLUMN pubkey_proven INTEGER NOT NULL DEFAULT 0"
        )


def migrate_nodes_edges_sync_columns() -> None:
    """Idempotent, additive migration (schema slice 3a — design.md "Slice 3
    in three sub-slices"): add `uuid`, `lamport`, `origin_node`,
    `deleted_at` to `nodes` and `edges`.

    A fresh DB already has all four columns via `_SCHEMA`'s
    `CREATE TABLE IF NOT EXISTS` — this only fires for a DB created BEFORE
    this change (mirrors `migrate_devices_pubkey_proven`). Purely additive:
    nothing in the codebase reads these columns yet (the sync engine that
    will is a later, separate PR) — this slice's whole contract is zero
    observable behavior change.

    SQLite's `ALTER TABLE ... ADD COLUMN` cannot attach a UNIQUE
    constraint, so `uuid` uniqueness is enforced by a UNIQUE INDEX created
    AFTER backfill, not by a column constraint (SQLite tolerates any number
    of NULLs in a UNIQUE index, so the same index also works on a freshly
    created, empty table).

    Runs one non-destructive step at a time (add missing columns -> backfill
    NULL uuids -> create the unique index) for `nodes`, then for `edges`.
    Every statement commits individually (this connection is opened with
    isolation_level=None), and every step re-checks the CURRENT
    schema/data state before acting. That combination is what makes a
    process kill between any two steps — e.g. after `nodes` finishes but
    before `edges` starts — safe to resume: a re-run only performs the
    steps that did not happen yet and never reassigns a `uuid` that was
    already backfilled. It is also why the backfill loop below is safe to
    call on every `init_db()` (like the rest of this migration): it
    converges any row still missing a `uuid` — including an ordinary row
    written after this slice shipped, since nothing yet sets `uuid` at
    insert time — without ever touching a row that already has one.
    """
    c = _connect()
    for table in ("nodes", "edges"):
        existing = {r[1] for r in c.execute(f"PRAGMA table_info({table})").fetchall()}
        for column, coltype in (
            ("uuid", "TEXT"),
            ("lamport", "INTEGER"),
            ("origin_node", "TEXT"),
            ("deleted_at", "REAL"),
        ):
            if column not in existing:
                c.execute(f"ALTER TABLE {table} ADD COLUMN {column} {coltype}")
        # Backfill only rows still missing a uuid — never re-touches a row
        # that already has one, which is what makes this resumable/idempotent.
        missing = c.execute(f"SELECT id FROM {table} WHERE uuid IS NULL").fetchall()
        for (row_id,) in missing:
            c.execute(
                f"UPDATE {table} SET uuid = ? WHERE id = ?",
                (str(uuid.uuid4()), row_id),
            )
        c.execute(
            f"CREATE UNIQUE INDEX IF NOT EXISTS idx_{table}_uuid ON {table}(uuid)"
        )


def migrate_edge_endpoint_uuids() -> None:
    """Idempotent, additive migration (PR5 "Expand" — design-schema.md
    Decision 2 step 1): add `edges.src_uuid`, `edges.dst_uuid`,
    `edges.updated_at`, `edges.relation`, and `nodes.occurred_at`; backfill
    `src_uuid`/`dst_uuid` from `nodes.uuid` via the existing `from_id`/
    `to_id` FKs, and `updated_at = created_at`.

    `relation` is added as `GENERATED ALWAYS AS (kind) VIRTUAL` — a single
    storage cell shared with `kind` (not a copy), so `relation` and `kind`
    CANNOT drift apart by construction. This is the fix for the
    kind/relation silent-mis-mapping failure design-schema.md names; a
    plain copy would reintroduce exactly that drift risk.

    A fresh DB gets all four `edges` columns natively via `_SCHEMA`'s
    `CREATE TABLE IF NOT EXISTS` (matching the PR4 pattern) — so on a fresh
    DB, this function's ALTER-TABLE branches are skipped (columns already
    exist) but it still RUNS, unconditionally, on every `init_db()` call
    (mirrors `migrate_nodes_edges_sync_columns`); its backfill loop is then
    a genuine no-op there for the ordinary reason (zero rows yet), not
    because the call itself was skipped. This migration is itself PURELY
    ADDITIVE and reversible — it only ever adds columns and fills them in.

    WHAT CHANGED UNDER IT SINCE. PR6 rewrote the readers, so `src_uuid`/
    `dst_uuid`/`relation` are what every graph read resolves through, and
    PR8's `migrate_rebuild_graph_tables()` then DROPPED `from_id`/`to_id`/
    `kind` outright. On a database that has been through the rebuild the
    backfill loop below has nothing to read FROM and skips itself (see the
    `if "from_id" in existing_edges` guard); the loop stays because a
    database that has NOT been rebuilt yet still needs it.

    `nodes.occurred_at` already exists in production via the pre-existing
    `migrate_nodes_occurred_at()` migration (added independently, before
    this design was written) — the guard below is a no-op there, kept for
    documentation/defence-in-depth so this migration is self-contained if
    ever run standalone against a DB that somehow lacks it.

    Requires `nodes.uuid` to already exist (schema slice 3a /
    `migrate_nodes_edges_sync_columns`, which `init_db()` runs first).

    Only touches edge rows where `src_uuid IS NULL` — never re-touches an
    already-backfilled row, matching `migrate_nodes_edges_sync_columns`'s
    resumable/idempotent pattern. Ends by calling
    `verify_edge_endpoint_convergence()` so a migration that silently
    mis-backfilled a row is caught immediately, not discovered later.
    """
    c = _connect()
    # table_xinfo, not table_info: table_info hides GENERATED/hidden columns
    # in this SQLite build, so a plain table_info check would never see
    # `relation` as already-present and would re-run the ALTER on every call,
    # raising "duplicate column name" on the second `init_db()`.
    existing_edges = {r[1] for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()}
    if "src_uuid" not in existing_edges:
        c.execute("ALTER TABLE edges ADD COLUMN src_uuid TEXT")
    if "dst_uuid" not in existing_edges:
        c.execute("ALTER TABLE edges ADD COLUMN dst_uuid TEXT")
    if "updated_at" not in existing_edges:
        c.execute("ALTER TABLE edges ADD COLUMN updated_at REAL")
    if "relation" not in existing_edges:
        c.execute(
            "ALTER TABLE edges ADD COLUMN relation TEXT "
            "GENERATED ALWAYS AS (kind) VIRTUAL"
        )

    existing_nodes = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    if "occurred_at" not in existing_nodes:
        c.execute("ALTER TABLE nodes ADD COLUMN occurred_at REAL")

    # Indexes on the columns PR6's rewritten reads join and filter on. Created
    # here too (not only in _SCHEMA) so a pre-existing DB that reaches the new
    # readers via ALTER TABLE gets them as well — otherwise every graph read on
    # the owner's real database becomes a full scan the moment PR6 lands.
    c.execute("CREATE INDEX IF NOT EXISTS idx_edges_src      ON edges(src_uuid)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_edges_dst      ON edges(dst_uuid)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_edges_relation ON edges(relation)")
    # PR7 (tombstones), same reasoning one level further on: every node and edge
    # read now filters `deleted_at IS NULL`, and the owner's real database is a
    # pre-existing one that never runs _SCHEMA's CREATE TABLE body.
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_nodes_deleted ON nodes(deleted_at) "
        "WHERE deleted_at IS NOT NULL"
    )
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_edges_deleted ON edges(deleted_at) "
        "WHERE deleted_at IS NOT NULL"
    )

    # Backfill every edge still missing EITHER endpoint uuid — resumable and
    # idempotent. `src_uuid IS NULL` alone was not enough: before task 5.14 an
    # edge from an already-uuid'd node to a node created after the last restart
    # dual-wrote a real src_uuid and a NULL dst_uuid, which that predicate
    # skipped forever. From PR6 on, such a row is invisible to every read that
    # resolves through dst_uuid.
    # After PR8's rebuild there is no `from_id`/`to_id` to backfill FROM — the
    # uuid endpoints are the only representation and are NOT NULL. Skipping is
    # correct, not a silent degradation: the state this loop repairs cannot
    # exist any more. Left running (rather than deleted) because a database
    # that has not been rebuilt yet still needs it.
    if "from_id" in existing_edges:
        rows = c.execute(
            "SELECT e.id, n1.uuid, n2.uuid, e.created_at "
            "FROM edges e "
            "JOIN nodes n1 ON n1.id = e.from_id "
            "JOIN nodes n2 ON n2.id = e.to_id "
            "WHERE e.src_uuid IS NULL OR e.dst_uuid IS NULL"
        ).fetchall()
        for edge_id, src_uuid, dst_uuid, created_at in rows:
            c.execute(
                # COALESCE: a half-backfilled row may already carry a real
                # updated_at, and this repair must not rewind it to created_at.
                "UPDATE edges SET src_uuid = ?, dst_uuid = ?, "
                "updated_at = COALESCE(updated_at, ?) WHERE id = ?",
                (src_uuid, dst_uuid, created_at, edge_id),
            )

    verify_edge_endpoint_convergence()


def verify_edge_endpoint_convergence() -> None:
    """Assert every live edge has usable uuid endpoints.

    WHAT THIS CHECKS DEPENDS ON WHETHER THE DATABASE HAS BEEN REBUILT — and
    on a rebuilt one (every database, after the first startup on PR8) it is
    the NULL-endpoint half ALONE:

    * Before PR8's `migrate_rebuild_graph_tables()` there were two endpoint
      representations, so this also compared `src_uuid`/`dst_uuid` against
      `from_id`/`to_id` (via `nodes.uuid`) and RAISED on the first drift.
    * After the rebuild those rowid columns do not exist. `src_uuid`/
      `dst_uuid` ARE the endpoints, there is nothing to drift FROM, and the
      comparison is skipped rather than allowed to raise "could not execute"
      on every startup — which would take `init_db()` down with it. See the
      `has_rowid_endpoints` guard in the body.

    RAISES ALSO if the check itself cannot execute (e.g. a table/column is
    missing mid-migration) — per the LifeOS silent-failure rule, a check
    that cannot run must fail loudly too, not merely a check that finds
    real drift. A check that quietly no-ops because its table vanished
    would be indistinguishable from "everything converged".

    RAISES ALSO on a NULL endpoint uuid, even when the node's own uuid is
    NULL too. That case used to read as "converged", because the equality
    is NULL IS NOT NULL — false — so the guard was blind to exactly the
    state it exists to catch. Harmless while nothing read the column; from
    PR6 (the reader rewrite) on, a NULL endpoint does not match the join
    and the edge simply vanishes from the result with no error and no log:
    a link missing from the user's own memory graph, indistinguishable
    from lost data. Nothing can produce that state any more (`add_node`
    assigns a uuid at insert, all three edge-insert paths copy it in the
    same transaction, and `migrate_edge_endpoint_uuids` backfills either
    endpoint), which is precisely why reaching it must be loud rather than
    tolerated in the readers.

    Available standalone (not just from `migrate_edge_endpoint_uuids`) for
    CI/regression use.
    """
    c = _connect()
    try:
        # After PR8's rebuild there is no second endpoint representation to
        # drift FROM: `src_uuid`/`dst_uuid` ARE the endpoints. The drift half
        # of this check becomes structurally impossible, so it is skipped
        # rather than allowed to raise "could not execute" on every startup —
        # which is what a plain `no such column: from_id` here would do, and it
        # would take init_db() down with it. The NULL-endpoint half below still
        # runs; it is now also enforced by `NOT NULL`, and belt-and-braces on
        # the invariant that PR6's readers depend on is cheap.
        has_rowid_endpoints = "from_id" in {
            r[1] for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()
        }
        mismatches = c.execute(
            "SELECT e.id, e.src_uuid, n1.uuid, e.dst_uuid, n2.uuid "
            "FROM edges e "
            "JOIN nodes n1 ON n1.id = e.from_id "
            "JOIN nodes n2 ON n2.id = e.to_id "
            "WHERE e.src_uuid IS NOT n1.uuid OR e.dst_uuid IS NOT n2.uuid"
        ).fetchall() if has_rowid_endpoints else []
        null_endpoints = c.execute(
            "SELECT id, src_uuid, dst_uuid FROM edges "
            "WHERE src_uuid IS NULL OR dst_uuid IS NULL"
        ).fetchall()
    except Exception as exc:  # noqa: BLE001 — deliberately broad: ANY failure
        # to execute the check must raise, not be swallowed.
        raise RuntimeError(
            f"verify_edge_endpoint_convergence: could not execute the "
            f"convergence check (table/column missing mid-migration?): {exc}"
        ) from exc
    # Rows are formatted by hand rather than interpolated. A sqlite Row's repr
    # is `<sqlcipher3.dbapi2.Row object at 0x...>`, so the raw f-string made
    # every one of these failures unactionable: it told you something broke and
    # nothing about what. A check that fires without naming the offending row
    # is only half a check.
    if mismatches:
        detail = "; ".join(
            f"id={r[0]} src_uuid={r[1]!r} expected={r[2]!r} "
            f"dst_uuid={r[3]!r} expected={r[4]!r}"
            for r in mismatches[:5]
        )
        raise RuntimeError(
            f"verify_edge_endpoint_convergence: {len(mismatches)} edge(s) "
            f"have drifted src_uuid/dst_uuid from from_id/to_id: {detail}"
        )
    if null_endpoints:
        detail = "; ".join(
            f"id={r[0]} src_uuid={r[1]!r} dst_uuid={r[2]!r}"
            for r in null_endpoints[:5]
        )
        raise RuntimeError(
            f"verify_edge_endpoint_convergence: {len(null_endpoints)} edge(s) "
            f"carry a NULL endpoint uuid and are therefore invisible to every "
            f"read that resolves edges through src_uuid/dst_uuid: {detail}"
        )


def report_dangling_edges(conn=None) -> list[str]:
    """Report live edges whose endpoint uuid resolves to no LIVE node.

    REPORT-ONLY on purpose (task 7.14). A dangling endpoint is LEGAL in
    mobile's model — referential integrity moves to the application after PR8
    and an edge may legitimately sync before its node arrives — so raising
    would turn a normal sync ordering into a crash. It still has to be
    visible: an endpoint that never arrives is a permanently broken link, and
    silently ignoring it is how that stops being anyone's problem.

    A tombstoned edge is never reported. Every ordinary node delete tombstones
    the node AND its edges, so reporting those would bury the real findings
    under one entry per deletion the user has ever made.

    RAISES if the check itself cannot execute — report-only applies to the
    FINDINGS, not to the check. Per the LifeOS silent-failure rule, returning
    "nothing wrong" because the query failed is the failure mode this codebase
    has already had to fix once.

    Returns one human-readable line per offending edge, each naming the edge
    id and both endpoint uuids — formatted by hand, never by interpolating a
    sqlite Row, whose repr says nothing.
    """
    c = conn or _connect()
    try:
        rows = c.execute(
            "SELECT e.id, e.src_uuid, e.dst_uuid, "
            "  (SELECT 1 FROM nodes n WHERE n.uuid = e.src_uuid "
            "     AND n.deleted_at IS NULL) AS src_live, "
            "  (SELECT 1 FROM nodes n WHERE n.uuid = e.dst_uuid "
            "     AND n.deleted_at IS NULL) AS dst_live "
            "FROM edges e "
            "WHERE e.deleted_at IS NULL "
            "  AND (src_live IS NULL OR dst_live IS NULL)"
        ).fetchall()
    except Exception as exc:  # noqa: BLE001 — deliberately broad: ANY failure
        # to execute the check must raise, not be swallowed.
        raise RuntimeError(
            f"report_dangling_edges: the dangling-edge check could not run "
            f"(table/column missing mid-migration?): {exc}"
        ) from exc

    out: list[str] = []
    for r in rows:
        missing = []
        if r[3] is None:
            missing.append(f"src_uuid={r[1]!r}")
        if r[4] is None:
            missing.append(f"dst_uuid={r[2]!r}")
        out.append(
            f"id={r[0]} points at no live node: " + ", ".join(missing)
        )
    if out:
        log.warning(
            "report_dangling_edges: %d live edge(s) point at a missing or "
            "deleted node (legal per the sync design, reported not enforced): %s",
            len(out), "; ".join(out[:5]),
        )
    return out


#: How a pre-rebuild snapshot is named on disk, as a glob.
#:
#: DUPLICATED, on purpose and with a test: `verified_pre_rebuild_backup()`
#: builds the same name with an f-string. Sharing one constant would mean
#: editing the writer, and the writer is the one function on this path that
#: must not be touched casually. `test_pre_rebuild_snapshot_visibility.py`
#: asserts the two still agree, so a rename cannot make this report go quietly
#: blind — which is the only failure mode that would matter here.
_PRE_REBUILD_SNAPSHOT_GLOB = ".pre-rebuild-*.db"


def report_pre_rebuild_snapshots() -> list[dict[str, Any]]:
    """List the pre-rebuild snapshots sitting beside the live database.

    WHY THIS EXISTS. `migrate_rebuild_graph_tables()` writes
    `memory.db.pre-rebuild-<epoch>.db` and NEVER deletes it. That is correct —
    it is the only rollback there is, and a process that removed its own
    rollback would be worse than one that leaves a file behind. But nothing
    told the user the file existed, and the cost is not small: measured on a
    realistic graph (8k nodes, 20k edges) the live database went from 20.6 MB
    to 36.3 MB and the snapshot added 19.8 MB, so 20.6 MB of memory became
    56.1 MB on disk — about 2.7x. Left unannounced that is either disk the
    user pays for forever, or a mysterious `memory.db.*.db` they delete months
    later without knowing it was the one copy that could have saved them.

    Newest first: the most recent snapshot is the one that matches the current
    database. Returns `path`, `bytes`, `modified_at` and the live database's
    own `live_db_bytes`, because "there is a file" is not actionable and "it
    costs you this much next to a database this size" is.

    Read-only and side-effect free. Raises on an unreadable directory rather
    than reporting "no snapshots" — a check that cannot run must not look like
    a check that ran and found nothing. The startup caller is what decides
    that this particular report is not worth failing to boot over.
    """
    live_bytes = DB_PATH.stat().st_size if DB_PATH.exists() else 0
    found = [
        {
            "path": str(p),
            "bytes": p.stat().st_size,
            "modified_at": p.stat().st_mtime,
            "taken_at": _pre_rebuild_snapshot_epoch(p),
            "live_db_bytes": live_bytes,
        }
        for p in DB_PATH.parent.glob(DB_PATH.name + _PRE_REBUILD_SNAPSHOT_GLOB)
        if p.is_file()
    ]
    # By the epoch the snapshot NAMES, not by mtime: a copy or a restore
    # rewrites mtime, and the stamp is what identifies which rebuild it
    # belongs to. mtime is the fallback for a name that cannot be parsed.
    found.sort(key=lambda f: (f["taken_at"] or f["modified_at"]), reverse=True)
    return found


def _pre_rebuild_snapshot_epoch(path: Path) -> int | None:
    """The `<epoch>` out of `memory.db.pre-rebuild-<epoch>.db`, or None."""
    stem = path.name.removesuffix(".db").rsplit(".pre-rebuild-", 1)
    if len(stem) != 2 or not stem[1].isdigit():
        return None
    return int(stem[1])


# ─────────────────── PR8: the pre-rebuild backup gate ───────────────────────
#
# PR8 rebuilds `nodes`/`edges` and drops `from_id`/`to_id`/`kind`. There is no
# code-level revert past that point: `git revert` gives you code that queries
# columns which no longer exist on disk. The ONLY recovery path is
# restore-from-verified-backup, so the backup is not a precaution here — it is
# the entire rollback plan, and a backup that was WRITTEN but cannot be
# RESTORED is worse than none, because it is trusted.


class MigrationBackupError(RuntimeError):
    """The pre-rebuild snapshot could not be taken, or could not be PROVEN
    restorable. Either way the rebuild must not start."""


# Tables whose row counts must match between the live DB and the snapshot.
# `nodes_fts` is included even though it is local derived state: a snapshot
# that silently lost the search index restores a graph whose search box is
# empty, and the user would meet that months later with no way back.
_BACKUP_PARITY_TABLES = ("nodes", "edges", "nodes_fts")

# How many (id, uuid) pairs to spot-check per table. Row counts can match while
# the rows themselves are wrong; this is the half that notices.
_BACKUP_SAMPLE_SIZE = 25


def _vacuum_into(dest: Path) -> None:
    """Write a transactional snapshot of the live DB to *dest*.

    `VACUUM INTO` rather than a file copy: it is transactional and therefore
    safe against concurrent writers, which a copy under journal activity is
    not — a torn copy is exactly the un-restorable backup this gate exists to
    catch. Separated from the verification below so tests can substitute a
    deliberately damaged snapshot and exercise the REAL verification code.
    """
    _connect().execute("VACUUM INTO ?", (str(dest),))


def _verify_snapshot(dest: Path, reference: dict | None = None) -> None:
    """Prove the snapshot at *dest* is restorable. Raises on any doubt.

    Three checks, in order, per design-schema.md Decision 5:
      1. it opens with the same SQLCipher key,
      2. `PRAGMA integrity_check` says `ok` — structurally sound,
      3. row-count parity plus a sampled `(id, uuid)` spot-check — a truncated
         database passes `integrity_check` perfectly well.

    *reference* maps table -> (row_count, max_rowid) as measured on the LIVE
    database immediately BEFORE the snapshot was taken. Parity is judged
    against it rather than against live-right-now, because this runs holding no
    lock and live keeps moving.

    Raises `MigrationBackupError` if any check fails OR if any check cannot be
    executed at all. A verification that quietly no-ops because the file would
    not open is indistinguishable from "the backup is fine".
    """
    live = _connect()
    try:
        snap = sqlcipher3.connect(str(dest), isolation_level=None)
    except Exception as exc:  # noqa: BLE001
        raise MigrationBackupError(
            f"pre-rebuild snapshot {dest} could not be opened at all: {exc}"
        ) from exc
    try:
        snap.execute(f"PRAGMA key = \"x'{load_key()}'\"")
        # The snapshot carries `vec_nodes` (a vec0 virtual table) and the
        # trigger that references it. Without the extension, any statement
        # SQLite has to compile against them fails with "no such module: vec0",
        # which would read as a corrupt backup. Best-effort: the checks below
        # only touch ordinary tables, so an unloadable extension must not by
        # itself condemn a good snapshot.
        try:
            _load_sqlite_vec(snap)
        except Exception:  # noqa: BLE001
            pass
        try:
            result = snap.execute("PRAGMA integrity_check").fetchone()
        except Exception as exc:  # noqa: BLE001
            raise MigrationBackupError(
                f"pre-rebuild snapshot {dest} could not be read with the "
                f"database key — it is not restorable: {exc}"
            ) from exc
        if not result or str(result[0]).lower() != "ok":
            raise MigrationBackupError(
                f"pre-rebuild snapshot {dest} failed integrity_check "
                f"({result[0] if result else 'no result'}) — it was written but "
                "cannot be restored"
            )
        # Parity is checked WITHIN THE SNAPSHOT'S OWN ID RANGE, not against the
        # live table as a whole. `VACUUM INTO` captures the database as of when
        # it starts, and this verification runs afterwards holding no lock, so
        # a plain COUNT comparison measures the snapshot against a moving
        # target: any write arriving in between made live > snapshot and
        # condemned a perfectly good backup.
        #
        # That is not theoretical. Running the rebuild under four concurrent
        # writers aborted the migration with "`nodes` has 3039 rows, the live
        # database has 3051". In production axi starts alongside the recorder,
        # the wakeword loop and the write-router, so this would raise inside
        # init_db(), the daemon would refuse to boot, and every restart would
        # repeat it — the user meets that as "axi is dead", not as a backup
        # problem.
        #
        # The two cases separate cleanly: a TORN copy loses arbitrary rows,
        # while concurrent writes only ADD rows with higher ids. So compare the
        # snapshot against the live rows it could possibly have contained.
        for table in _BACKUP_PARITY_TABLES:
            ref_n, ref_max = reference.get(table, (None, None))
            try:
                # nodes_fts is a virtual FTS5 table whose rowid is the node id;
                # `MAX(rowid)` works for both shapes.
                snap_n = snap.execute(
                    f"SELECT COUNT(*) FROM {table} WHERE rowid <= ?", (ref_max,)
                ).fetchone()[0] if ref_max is not None else snap.execute(
                    f"SELECT COUNT(*) FROM {table}"
                ).fetchone()[0]
            except Exception as exc:  # noqa: BLE001
                raise MigrationBackupError(
                    f"pre-rebuild snapshot {dest}: row-count parity for "
                    f"`{table}` could not be checked: {exc}"
                ) from exc
            # Compared against the reference taken just BEFORE the vacuum, not
            # against live now. Live is a moving target — this verification
            # holds no lock — so a plain comparison condemned a good snapshot
            # the instant any other thread wrote. A snapshot may hold MORE than
            # the reference (a write landing between the count and the vacuum's
            # start); it may never hold LESS, which is loss.
            if ref_n is not None and snap_n < ref_n:
                raise MigrationBackupError(
                    f"pre-rebuild snapshot {dest}: `{table}` has {snap_n} rows "
                    f"up to id {ref_max}, the live database had {ref_n} when the "
                    "snapshot was taken — the snapshot is missing data and must "
                    "not be relied on"
                )
        # Sampled FROM THE SNAPSHOT, checked against live — not the reverse.
        # Sampling live and looking rows up in the snapshot fails the moment a
        # concurrent write lands, for the same reason the count did: live holds
        # rows the snapshot legitimately predates. Every row the snapshot DOES
        # hold must match live exactly; rows added afterwards are none of this
        # check's business.
        #
        # Head AND tail. The original took `ORDER BY id LIMIT 25` — the 25
        # OLDEST rows — but a torn copy loses the TAIL, which is precisely the
        # half that sampling never looked at. Row-count parity catches a
        # missing tail; value-level corruption in it went uninspected.
        half = max(1, _BACKUP_SAMPLE_SIZE // 2)
        for table in ("nodes", "edges"):
            sample = snap.execute(
                f"SELECT id, uuid FROM (SELECT id, uuid FROM {table} "
                f"                      ORDER BY id LIMIT ?) "
                f"UNION "
                f"SELECT id, uuid FROM (SELECT id, uuid FROM {table} "
                f"                      ORDER BY id DESC LIMIT ?)",
                (half, half),
            ).fetchall()
            for row_id, row_uuid in sample:
                got = live.execute(
                    f"SELECT uuid FROM {table} WHERE id = ?", (row_id,)
                ).fetchone()
                if got is None or got[0] != row_uuid:
                    raise MigrationBackupError(
                        f"pre-rebuild snapshot {dest}: `{table}` id={row_id} holds "
                        f"uuid={row_uuid!r}, the live database has "
                        f"{None if got is None else got[0]!r} — the snapshot does "
                        "not hold the same rows"
                    )
    finally:
        snap.close()


def verified_pre_rebuild_backup() -> str:
    """Take a snapshot of the graph and PROVE it restorable. Returns its path.

    This is the default `backup` callable of `migrate_rebuild_graph_tables`.
    It is a callable rather than inline code so tests can drive fake success,
    fake failure and a fake corrupt snapshot without a real device or key
    ceremony (task 8.5).
    """
    dest = DB_PATH.parent / f"{DB_PATH.name}.pre-rebuild-{int(time.time())}.db"
    if dest.exists():
        dest.unlink()
    # Anchor the parity check to what live held BEFORE the snapshot. Verifying
    # against live afterwards compares the snapshot to a moving target: under
    # concurrent writers — which is every real axi startup, alongside the
    # recorder and write-router threads — that condemned a perfectly good
    # backup and left the daemon refusing to boot on every restart.
    reference: dict[str, tuple[int, int | None]] = {}
    try:
        _ref_conn = _connect()
        for _t in _BACKUP_PARITY_TABLES:
            _n = _ref_conn.execute(f"SELECT COUNT(*) FROM {_t}").fetchone()[0]
            _m = _ref_conn.execute(f"SELECT MAX(rowid) FROM {_t}").fetchone()[0]
            reference[_t] = (_n, _m)
    except Exception as exc:  # noqa: BLE001
        # Fail loudly: without the reference the parity check has nothing
        # trustworthy to compare against, and guessing is how a torn backup
        # gets blessed.
        raise MigrationBackupError(
            f"pre-rebuild snapshot: could not measure the live database before "
            f"snapshotting, so the snapshot cannot be verified: {exc}"
        ) from exc
    try:
        _vacuum_into(dest)
    except Exception as exc:  # noqa: BLE001
        # The numbers matter more than the cause. This failure surfaces to the
        # user as "axi will not start" — init_db lets it propagate on purpose,
        # because migrating without a recovery path is the one thing worse than
        # not starting. So the message has to say what to DO. Measured: the
        # snapshot needs roughly the size of the live database.
        try:
            _needed = DB_PATH.stat().st_size
            _free = shutil.disk_usage(DB_PATH.parent).free
            _space = (
                f" The snapshot needs about {_needed / 1e6:.0f} MB "
                f"({_free / 1e6:.0f} MB free on that filesystem); free some "
                f"space and start axi again."
            )
        except Exception:  # noqa: BLE001 — never let diagnostics hide the error
            _space = ""
        raise MigrationBackupError(
            f"pre-rebuild snapshot could not be written to {dest}: {exc}."
            f"{_space} Nothing was migrated and your graph is untouched."
        ) from exc
    _verify_snapshot(dest, reference)
    log.warning(
        "verified_pre_rebuild_backup: verified snapshot at %s — this file is "
        "the ONLY recovery path for the graph table rebuild", dest,
    )
    return str(dest)


# ──────────── PR8: the single-transaction rebuild (point of no return) ──────

# `PRAGMA user_version` after the rebuild. Design-schema.md Decision 6 numbers
# the stages PR5=1, PR7=2, PR8=3; only this one needs a gate, because only this
# one cannot be re-run harmlessly.
GRAPH_REBUILD_USER_VERSION = 3

# Mobile's exact DDL (`mobile/lib/core/graph/local_graph_schema.dart`), which
# is the target contract: axi converges, mobile does not move.
#
# TWO deliberate additions, both axi-only LOCAL DERIVED STATE of exactly the
# kind design-schema.md already exempts for `nodes_fts`/`vec_nodes`:
# `embedding`/`embedding_model`/`embedding_dim`. They are not in mobile's DDL
# because mobile has no embedder. Dropping them here would silently destroy
# every embedding in the graph — recall and the whole RAG path — with no error
# and no failing test, which is the failure mode this entire phase is built to
# avoid. Column ORDER follows mobile's; the axi-only columns are appended last.
_NODES_REBUILT_DDL = """
CREATE TABLE nodes_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid         TEXT    NOT NULL UNIQUE,
  kind         TEXT    NOT NULL,
  label        TEXT    NOT NULL,
  data         TEXT,
  domain       TEXT,
  occurred_at  REAL,
  created_at   REAL    NOT NULL,
  updated_at   REAL    NOT NULL,
  created_tz   TEXT,
  origin_node  TEXT,
  lamport      INTEGER NOT NULL DEFAULT 0,
  deleted_at   REAL,
  embedding       BLOB,
  embedding_model TEXT,
  embedding_dim   INTEGER
)
"""

# `relation` is now REAL storage, not a generated alias of `kind`, and the
# `from_id`/`to_id` FK columns are gone — so the `ON DELETE CASCADE` that
# silently destroyed edges on a hard node delete ceases to exist because the
# columns carrying it do. Referential integrity moves to the application,
# matching mobile, where a dangling `src_uuid` is legal by design (an edge may
# sync before its node). `report_dangling_edges` is the loud, report-only check.
_EDGES_REBUILT_DDL = """
CREATE TABLE edges_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid         TEXT    NOT NULL UNIQUE,
  src_uuid     TEXT    NOT NULL,
  dst_uuid     TEXT    NOT NULL,
  relation     TEXT    NOT NULL,
  data         TEXT,
  created_at   REAL    NOT NULL,
  updated_at   REAL    NOT NULL,
  origin_node  TEXT,
  lamport      INTEGER NOT NULL DEFAULT 0,
  deleted_at   REAL
)
"""

# DROP TABLE takes every index on that table with it and the RENAME does not
# bring them back (measured, not assumed). Without this, every graph read
# silently degrades to a full table scan: correct answers, no failing test,
# just a memory graph that gets slower forever.
_GRAPH_INDEX_DDL = (
    "CREATE INDEX IF NOT EXISTS idx_nodes_kind    ON nodes(kind)",
    "CREATE INDEX IF NOT EXISTS idx_nodes_domain  ON nodes(domain)",
    "CREATE INDEX IF NOT EXISTS idx_nodes_created ON nodes(created_at)",
    # Redundant with the column-level UNIQUE, but `migrate_nodes_edges_sync_columns`
    # recreates it on the very next startup regardless; creating it here keeps
    # the post-rebuild schema identical to the steady state instead of changing
    # shape one restart later.
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_uuid ON nodes(uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_edges_uuid ON edges(uuid)",
    "CREATE INDEX IF NOT EXISTS idx_edges_src      ON edges(src_uuid)",
    "CREATE INDEX IF NOT EXISTS idx_edges_dst      ON edges(dst_uuid)",
    "CREATE INDEX IF NOT EXISTS idx_edges_relation ON edges(relation)",
    # PARTIAL on purpose — see the comment on idx_nodes_deleted in _SCHEMA.
    # Name and column match mobile; only the predicate differs, and an index
    # predicate is a local planner concern, not a wire contract.
    "CREATE INDEX IF NOT EXISTS idx_nodes_deleted ON nodes(deleted_at) "
    "WHERE deleted_at IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_edges_deleted ON edges(deleted_at) "
    "WHERE deleted_at IS NOT NULL",
)


def _rebuild_preflight(c) -> None:
    """Refuse to start the rebuild if the data cannot satisfy mobile's
    constraints. Raises with the offending ids named.

    Without this the tightened `NOT NULL`s would surface as a bare
    `IntegrityError` from deep inside an `INSERT ... SELECT`, naming nothing.
    `init_db()` runs the backfills that make this impossible first; reaching it
    means something upstream is broken, and the message has to say what.
    """
    bad_nodes = c.execute("SELECT id FROM nodes WHERE uuid IS NULL LIMIT 5").fetchall()
    if bad_nodes:
        raise RuntimeError(
            "rebuild refused: node(s) with a NULL uuid cannot satisfy mobile's "
            f"`uuid NOT NULL` — ids {[r[0] for r in bad_nodes]}. Run "
            "migrate_nodes_edges_sync_columns() first."
        )
    bad_edges = c.execute(
        "SELECT id, src_uuid, dst_uuid, uuid FROM edges "
        "WHERE uuid IS NULL OR src_uuid IS NULL OR dst_uuid IS NULL LIMIT 5"
    ).fetchall()
    if bad_edges:
        detail = "; ".join(
            f"id={r[0]} src_uuid={r[1]!r} dst_uuid={r[2]!r} uuid={r[3]!r}"
            for r in bad_edges
        )
        raise RuntimeError(
            "rebuild refused: edge(s) with a NULL uuid or endpoint cannot "
            f"satisfy mobile's NOT NULL columns — {detail}. Run "
            "migrate_edge_endpoint_uuids() first."
        )


def _rebuild_copy_rows(tx) -> None:
    """Copy every row into the new tables with an EXPLICIT `id`.

    Never `INSERT INTO nodes_new(...) SELECT` without the id: AUTOINCREMENT
    would reassign them, and `conversations.node_id`, `meetings.node_id`,
    `reminders.related_node_id`, `domain_node_map.node_id` and every
    `nodes_fts.rowid` address nodes by exactly that integer. A reassignment
    re-attaches each of them to a DIFFERENT memory, with referential integrity
    still perfectly intact.

    Tombstoned rows are copied too. They ARE the user's deletions; dropping
    them here is how a deleted memory comes back on the next sync.
    """
    tx.execute(
        "INSERT INTO nodes_new(id, uuid, kind, label, data, domain, occurred_at, "
        "created_at, updated_at, created_tz, origin_node, lamport, deleted_at, "
        "embedding, embedding_model, embedding_dim) "
        "SELECT id, uuid, kind, label, data, domain, occurred_at, created_at, "
        "updated_at, created_tz, origin_node, COALESCE(lamport, 0), deleted_at, "
        "embedding, embedding_model, embedding_dim FROM nodes"
    )
    tx.execute(
        "INSERT INTO edges_new(id, uuid, src_uuid, dst_uuid, relation, data, "
        "created_at, updated_at, origin_node, lamport, deleted_at) "
        "SELECT id, uuid, src_uuid, dst_uuid, kind, data, created_at, "
        "COALESCE(updated_at, created_at), origin_node, COALESCE(lamport, 0), "
        "deleted_at FROM edges"
    )


def _rebuild_verify(tx) -> None:
    """Verify the copy while old and new tables COEXIST, before DROP/RENAME.

    Verifying after the rename verifies nothing: the evidence you would need —
    the old table — is already gone, so a check there can only compare the new
    table with itself.

    Raises on the first discrepancy, which rolls the whole transaction back and
    leaves the old schema fully intact.
    """
    for old, new in (("nodes", "nodes_new"), ("edges", "edges_new")):
        n_old = tx.execute(f"SELECT COUNT(*) FROM {old}").fetchone()[0]
        n_new = tx.execute(f"SELECT COUNT(*) FROM {new}").fetchone()[0]
        if n_old != n_new:
            raise RuntimeError(
                f"rebuild verification failed: `{old}` has {n_old} rows, "
                f"`{new}` has {n_new} — {abs(n_old - n_new)} row(s) would be "
                "lost. Rolling back; the old schema is untouched."
            )
        nulls = tx.execute(f"SELECT COUNT(*) FROM {new} WHERE uuid IS NULL").fetchone()[0]
        if nulls:
            raise RuntimeError(
                f"rebuild verification failed: {nulls} row(s) in `{new}` carry "
                "a NULL uuid"
            )
        # SUM-based checksums over the identity columns, as specified. Cheap,
        # order-independent, and it catches a wholesale column mis-mapping that
        # per-row counts alone would not.
        sums_old = tx.execute(
            f"SELECT SUM(id), SUM(LENGTH(uuid)) FROM {old}"
        ).fetchone()
        sums_new = tx.execute(
            f"SELECT SUM(id), SUM(LENGTH(uuid)) FROM {new}"
        ).fetchone()
        if tuple(sums_old) != tuple(sums_new):
            raise RuntimeError(
                f"rebuild verification failed: id/uuid checksums differ between "
                f"`{old}` {tuple(sums_old)} and `{new}` {tuple(sums_new)}"
            )
    # id -> uuid mapping intact, per row, both endpoints and the relation with
    # it. Strictly stronger than the checksums above; the checksums stay because
    # they fail on shapes an equality join cannot reach (e.g. an empty new
    # table joined against an empty old one).  `IS NOT` rather than `!=` so a
    # NULL on either side counts as a difference instead of an unknown.
    drift = tx.execute(
        "SELECT o.id FROM nodes o LEFT JOIN nodes_new n ON n.id = o.id "
        "WHERE n.uuid IS NOT o.uuid OR n.kind IS NOT o.kind "
        "   OR n.label IS NOT o.label OR n.data IS NOT o.data "
        "   OR n.created_at IS NOT o.created_at OR n.deleted_at IS NOT o.deleted_at "
        # The embedding columns are checked HERE, not left to construction.
        # axi's `nodes` carries them and mobile's does not, so the one edit
        # this rebuild invites — "make the DDL match mobile exactly" — deletes
        # every vector in the graph, taking recall and the whole RAG path with
        # it, silently and with a green suite. Verifying them in-transaction
        # turns that edit into a rollback instead of a loss. `domain`,
        # `occurred_at`, `created_tz`, `updated_at`, `origin_node` and
        # `lamport` are here for the same reason: a column that nothing
        # compares is a column the copy may quietly drop.
        "   OR n.embedding IS NOT o.embedding "
        "   OR n.embedding_model IS NOT o.embedding_model "
        "   OR n.embedding_dim IS NOT o.embedding_dim "
        "   OR n.domain IS NOT o.domain OR n.occurred_at IS NOT o.occurred_at "
        "   OR n.created_tz IS NOT o.created_tz OR n.updated_at IS NOT o.updated_at "
        "   OR n.origin_node IS NOT o.origin_node "
        # lamport is compared through the SAME COALESCE the copy applies. It is
        # the one column deliberately TRANSFORMED rather than carried (task
        # 8.12 tightens it to NOT NULL DEFAULT 0), so a raw comparison would
        # read that intended NULL->0 as drift and roll back every migration
        # with a legacy row in it.
        "   OR n.lamport IS NOT COALESCE(o.lamport, 0) "
        "LIMIT 5"
    ).fetchall()
    if drift:
        raise RuntimeError(
            "rebuild verification failed: node id->uuid/payload mapping does not "
            f"survive the copy for ids {[r[0] for r in drift]}"
        )
    drift = tx.execute(
        "SELECT o.id FROM edges o LEFT JOIN edges_new n ON n.id = o.id "
        "WHERE n.uuid IS NOT o.uuid OR n.src_uuid IS NOT o.src_uuid "
        "   OR n.dst_uuid IS NOT o.dst_uuid OR n.relation IS NOT o.relation "
        "   OR n.deleted_at IS NOT o.deleted_at "
        "LIMIT 5"
    ).fetchall()
    if drift:
        raise RuntimeError(
            "rebuild verification failed: edge endpoint/relation mapping does "
            f"not survive the copy for ids {[r[0] for r in drift]}"
        )


def migrate_rebuild_graph_tables(*, backup: Callable[[], str] | None = None) -> bool:
    """THE POINT OF NO RETURN: rebuild `nodes`/`edges` to mobile's exact DDL.

    Drops `from_id`/`to_id`/`kind` and the `ON DELETE CASCADE` FK with them,
    promotes `relation` to real storage, and tightens `uuid NOT NULL UNIQUE`
    and `lamport NOT NULL DEFAULT 0`. **There is no code-level revert past this
    point** — reverting the code leaves queries against columns that are no
    longer on disk. Recovery is restore-from-verified-backup, and nothing else,
    which is why *backup* runs first and raises rather than warns.

    Returns True if the rebuild ran, False if it was already applied
    (`PRAGMA user_version` gate — a re-run is a safe no-op, and a process
    killed anywhere before COMMIT leaves the old schema intact and unmigrated,
    so restarting is a clean retry).

    *backup* is injected so tests can drive fake success, fake failure and a
    fake corrupt snapshot without a real device or key ceremony. It defaults to
    `verified_pre_rebuild_backup`; there is no way to opt out of it.
    """
    c = _connect()
    if c.execute("PRAGMA user_version").fetchone()[0] >= GRAPH_REBUILD_USER_VERSION:
        return False
    if "from_id" not in {r[1] for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()}:
        # A fresh database is created at mobile's shape by _SCHEMA and has
        # nothing to rebuild; record that and stop.
        c.execute(f"PRAGMA user_version = {GRAPH_REBUILD_USER_VERSION}")
        return False

    _rebuild_preflight(c)
    snapshot = (backup or verified_pre_rebuild_backup)()
    log.warning(
        "migrate_rebuild_graph_tables: starting the IRREVERSIBLE graph table "
        "rebuild; verified snapshot at %s is the only way back", snapshot,
    )

    # PRAGMA foreign_keys is a no-op inside a transaction, so it must be set
    # here. The connection is autocommit (isolation_level=None, this module's
    # convention), which is exactly why the explicit BEGIN IMMEDIATE below is
    # mandatory rather than decorative.
    c.execute("PRAGMA foreign_keys=OFF")
    try:
        c.execute("BEGIN IMMEDIATE")
        try:
            c.execute("DROP TABLE IF EXISTS nodes_new")
            c.execute("DROP TABLE IF EXISTS edges_new")
            c.execute(_NODES_REBUILT_DDL)
            c.execute(_EDGES_REBUILT_DDL)
            _rebuild_copy_rows(c)
            _rebuild_verify(c)
            c.execute("DROP TABLE edges")
            c.execute("DROP TABLE nodes")
            c.execute("ALTER TABLE edges_new RENAME TO edges")
            c.execute("ALTER TABLE nodes_new RENAME TO nodes")
            for stmt in _GRAPH_INDEX_DDL:
                c.execute(stmt)
            # user_version lives in the database header and is transactional,
            # which is what makes it a trustworthy gate: a kill before COMMIT
            # rolls it back along with everything else.
            c.execute(f"PRAGMA user_version = {GRAPH_REBUILD_USER_VERSION}")
            c.execute("COMMIT")
        except BaseException:
            # BaseException, not Exception: a KeyboardInterrupt landing here is
            # precisely the "process killed mid-rebuild" case, and it must roll
            # back too rather than leave a half-built schema behind.
            c.execute("ROLLBACK")
            raise
    finally:
        c.execute("PRAGMA foreign_keys=ON")

    violations = c.execute("PRAGMA foreign_key_check").fetchall()
    if violations:
        log.error(
            "migrate_rebuild_graph_tables: %d foreign key violation(s) AFTER the "
            "rebuild: %s — restore from the snapshot at %s",
            len(violations), violations[:5], snapshot,
        )
        raise RuntimeError(
            f"rebuild left {len(violations)} foreign key violation(s); restore "
            f"from {snapshot}"
        )
    # DROP TABLE nodes destroyed the AFTER DELETE trigger that cleans up
    # vec_nodes, and the RENAME does not restore it. init_db() creates it
    # BEFORE the migrations run, so nothing would put it back until the next
    # startup.
    try:
        create_vec_nodes_table(c)
    except Exception as exc:  # noqa: BLE001 — sqlite-vec may be unloadable
        log.warning(
            "migrate_rebuild_graph_tables: could not restore the vec_nodes "
            "trigger after the rebuild: %s", exc,
        )
    log.warning("migrate_rebuild_graph_tables: rebuild COMMITTED — schema is now "
                "mobile's shape; %s is the only rollback", snapshot)
    return True


def hash_device_token(token: str) -> str:
    """SHA-256 hex digest of a raw device bearer token.

    Pure function, no I/O. The raw token is generated once at pairing time
    and shown to the user; only this hash is ever written to disk (D5) —
    callers must never persist the raw token anywhere.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


_DEVICE_COLUMNS = (
    "device_id, name, device_pubkey, pubkey_proven, created_at, last_seen_at, revoked_at"
)


def device_add(
    device_id: str,
    name: str,
    token: str,
    device_pubkey: str | None = None,
    pubkey_proven: bool = False,
) -> None:
    """Insert a new paired device, storing only the SHA-256 hash of *token*.

    `pubkey_proven` records whether `device_pubkey` was accompanied by a
    verified proof of possession at pairing time (spec `mesh-trust-hardening`
    — the caller, `api_v1.pair`, verifies the Ed25519 signature BEFORE
    calling this; `device_add` only records the outcome, it does not verify).
    Defaults False so a caller that forgets to pass it never accidentally
    claims a key is proven.

    Raises sqlcipher3.dbapi2.IntegrityError if device_id or the token hash
    already exists — a collision must never silently overwrite another
    device's identity or bearer token.
    """
    from axi import write_router  # lazy, avoid import cycle

    routed, _res = write_router.maybe_forward("device_add", {
        "device_id": device_id,
        "name": name,
        "token": token,
        "device_pubkey": device_pubkey,
        "pubkey_proven": pubkey_proven,
    })
    if routed:
        return _res
    with _tx() as c:
        c.execute(
            "INSERT INTO devices(device_id, name, token_hash, device_pubkey, "
            "pubkey_proven, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (
                device_id, name, hash_device_token(token), device_pubkey,
                int(pubkey_proven), time.time(),
            ),
        )


def device_list(include_revoked: bool = True) -> list[dict[str, Any]]:
    """Return paired devices for the config-page device list, newest first.

    Never includes token_hash — callers only need id/name/pubkey/timestamps
    for display and revocation actions.
    """
    c = _connect()
    query = f"SELECT {_DEVICE_COLUMNS} FROM devices"
    if not include_revoked:
        query += " WHERE revoked_at IS NULL"
    query += " ORDER BY created_at DESC"
    rows = c.execute(query).fetchall()
    return [dict(r) for r in rows]


def device_get_by_token_hash(token_hash: str) -> dict[str, Any] | None:
    """Look up a device by its token hash (auth middleware call site, M0-3+).

    Pure lookup, no policy: returns the row regardless of revoked_at — the
    caller decides whether a non-NULL revoked_at means reject the request.
    """
    c = _connect()
    row = c.execute(
        f"SELECT {_DEVICE_COLUMNS} FROM devices WHERE token_hash = ?",
        (token_hash,),
    ).fetchone()
    return dict(row) if row else None


def device_get_by_pubkey(device_pubkey: str) -> dict[str, Any] | None:
    """Look up a device row by its stored ``device_pubkey``.

    Pure lookup, mirrors :func:`device_get_by_token_hash`. This bridges the
    mesh trust core's revocation check — a membership cert only carries
    ``node_pubkey``, never ``device_id`` — to ``devices.revoked_at`` (see
    ``mesh_infer.default_is_revoked``, design "Revocation as an injected
    fail-closed callback"). A mesh node enrolled via the owner passphrase
    (not a paired phone) simply has no matching row here -> ``None``, which
    the caller treats as "not revoked", not as a lookup failure.
    """
    c = _connect()
    row = c.execute(
        f"SELECT {_DEVICE_COLUMNS} FROM devices WHERE device_pubkey = ?",
        (device_pubkey,),
    ).fetchone()
    return dict(row) if row else None


def device_sealing_pubkey(device_id: str) -> str | None:
    """Return ``device_pubkey`` for *device_id* ONLY if it has proof of
    possession on record (``pubkey_proven``); otherwise ``None``.

    Design "PoP reuses the existing Ed25519 request scheme" — migration
    note: any FUTURE sealed-box (K_sync) consumer MUST call this instead of
    reading ``device_pubkey`` directly. A key stored before PoP enforcement
    (or never proven) is treated as ABSENT — never used to seal data — until
    the device re-pairs with a valid proof of possession.
    """
    c = _connect()
    row = c.execute(
        "SELECT device_pubkey, pubkey_proven FROM devices WHERE device_id = ?",
        (device_id,),
    ).fetchone()
    if row is None or not row["pubkey_proven"]:
        return None
    return row["device_pubkey"]


def device_touch_last_seen(device_id: str) -> None:
    """Update last_seen_at to now for *device_id*. No-op if unknown."""
    from axi import write_router  # lazy, avoid import cycle

    routed, _res = write_router.maybe_forward("device_touch_last_seen", {
        "device_id": device_id,
    })
    if routed:
        return _res
    with _tx() as c:
        c.execute(
            "UPDATE devices SET last_seen_at = ? WHERE device_id = ?",
            (time.time(), device_id),
        )


def device_revoke(device_id: str) -> bool:
    """Set revoked_at = now for *device_id*. Returns True iff a row changed.

    Idempotent: a second revoke on an already-revoked device is a no-op
    (returns False) so the original revocation timestamp is never clobbered.
    """
    from axi import write_router  # lazy, avoid import cycle

    routed, _res = write_router.maybe_forward("device_revoke", {"device_id": device_id})
    if routed:
        return _res
    with _tx() as c:
        cur = c.execute(
            "UPDATE devices SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
            (time.time(), device_id),
        )
        return cur.rowcount > 0


# ─────────────────── fact-node creation (Slice 2) ────────────────────────────


def create_fact_node_for_interaction(interaction: Any) -> int | None:
    """Thin shim: create a fact node for a relationships interaction.

    Delegates entirely to domain_bridge.create_fact_node_for_entry so there is
    a single code path for relationships nodes.  Entry ids are always
    stringified (str(interaction.id)) ensuring the domain_node_map key is
    consistent whether the id is an int or a string.

    Args:
        interaction: any object with .id, .raw_utterance, .title, .body, .person_id

    Returns:
        The node_id of the fact node (new or existing).
    """
    from axi.domain_bridge import create_fact_node_for_entry  # noqa: PLC0415
    return create_fact_node_for_entry("relationships", interaction)


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
        "SELECT embedding, embedding_dim FROM nodes "
        "WHERE id = ? AND embedding IS NOT NULL AND deleted_at IS NULL",
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
                # Resolved through the endpoint uuids (PR6) — the same columns
                # the INSERT below writes, so the guard recognises an edge it
                # wrote itself instead of adding a second one on every pass.
                exists = c.execute(
                    "SELECT 1 FROM edges WHERE "
                    "src_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
                    "dst_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
                    "relation = 'similar-to' AND deleted_at IS NULL LIMIT 1",
                    (node_id, neighbor_id),
                ).fetchone()
                if exists is None:
                    # PR8: uuid endpoints, real `relation`, and an `uuid` of
                    # its own — see add_edge's identical rationale.
                    now = time.time()
                    src_uuid, dst_uuid = _require_endpoint_uuids(
                        c, node_id, neighbor_id
                    )
                    c.execute(
                        "INSERT INTO edges(uuid, src_uuid, dst_uuid, relation, "
                        "data, created_at, updated_at) "
                        "VALUES (?, ?, ?, 'similar-to', '{}', ?, ?)",
                        (str(uuid.uuid4()), src_uuid, dst_uuid, now, now),
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
    """Bounded backfill: create fact-nodes for recent relationships interactions.

    Thin wrapper that delegates to domain_bridge.backfill_all_domains scoped
    to the "relationships" domain. Rate-limiting and idempotency are handled
    there. Already-mapped entries are skipped (resumable).

    Returns the number of interactions newly bridged.
    """
    from axi.domain_bridge import backfill_all_domains

    result = backfill_all_domains(
        days=days,
        batch_size=batch_size,
        sleep_s=sleep_s,
        domains=["relationships"],
    )
    return result.get("relationships", 0)


def backfill_similar_to_edges(*, threshold: float = 0.85, node_limit: int | None = None) -> int:
    """Create similar-to edges for all nodes that already have embeddings.

    Iterates every node with a non-NULL embedding (that is also present in
    vec_nodes), calling check_and_create_similar_to_edges for each. Idempotent
    via INSERT OR IGNORE in the underlying helper.

    Args:
        threshold: Minimum cosine similarity for edge creation.
        node_limit: If set, process at most this many nodes (most-recent first).
                    None (default) processes all nodes.

    Returns the total number of new edges created across all nodes.
    """
    c = _connect()
    if node_limit is not None:
        rows = c.execute(
            "SELECT node_id FROM vec_nodes ORDER BY node_id DESC LIMIT ?",
            (node_limit,),
        ).fetchall()
    else:
        rows = c.execute("SELECT node_id FROM vec_nodes").fetchall()

    total = 0
    for row in rows:
        nid = int(row[0])
        try:
            total += check_and_create_similar_to_edges(nid, c, threshold=threshold)
        except Exception as exc:  # noqa: BLE001
            log.warning("backfill_similar_to_edges: failed for node %d: %s", nid, exc)

    return total


def close() -> None:
    """Close the calling thread's SQLite connections (memory.db + events.db)."""
    for attr in ("conn", "events_conn"):
        conn = getattr(_tl, attr, None)
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass
            setattr(_tl, attr, None)


_CORRUPTION_INDICATORS = (
    "disk image is malformed",
    "disk i/o error",
    "hmac check failed",
    "error decrypting",
    "file is not a database",
    "deferred error",
)


def is_corruption_error(exc: BaseException) -> bool:
    """True when *exc* looks like a SQLCipher page-level / latched-connection
    error (decrypt/hmac failure, malformed image, deferred error condition)."""
    msg = str(exc).lower()
    return any(ind in msg for ind in _CORRUPTION_INDICATORS)


def reset_connection() -> bool:
    """Drop and reopen the calling thread's memory.db connection to clear a
    latched SQLCipher "deferred error condition".

    When the on-disk file is HEALTHY but the live connection hit a transient
    decrypt/hmac error (e.g. a WAL/concurrency race between the dashboard, the
    daemon and the heartbeat all touching memory.db), SQLCipher latches that
    connection into a permanent error state — every subsequent statement on it
    fails even though the file is fine. The full recovery ladder
    (:func:`attempt_self_heal`) is overkill for that: we just need a fresh
    connection.

    This is the cheap first rung — safe to call repeatedly. Returns True when
    the reopened connection passes a trivial smoke read, False otherwise (in
    which case the caller should escalate to :func:`attempt_self_heal`).
    """
    try:
        close()  # drop the latched thread-local connection(s)
        c = _connect()  # reopen a fresh connection
        c.execute("SELECT 1").fetchone()  # smoke test — proves it decrypts
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("reset_connection: reopen failed: %s", exc)
        return False


# ─────────────────── periodic healthy-backup rotation ────────────────────────


def _guard_row_counts(conn: sqlcipher3.Connection) -> dict[str, int | None]:
    """Row counts for the guard tables on *conn* (None per table on any error)."""
    out: dict[str, int | None] = {}
    for t in _GUARD_TABLES:
        try:
            out[t] = conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        except Exception:  # noqa: BLE001 — missing table / read error ⇒ don't guard on it
            out[t] = None
    return out


def do_healthy_backup(db_path: Path = DB_PATH) -> None:
    """Write a known-good encrypted backup of *db_path* if it passes integrity_check.

    Rotates three named slots (1 = most recent):
      <db>.healthy-1.bak → most recent
      <db>.healthy-2.bak → previous
      <db>.healthy-3.bak → oldest (evicted on next rotation)

    Uses the SQLCipher online backup API so the snapshot is consistent even
    under concurrent reads. Non-fatal: all errors are caught and logged as
    WARNING so a backup failure never propagates into the daemon's event loop.

    Each backup file receives ``chattr +C`` (NOCOW) on btrfs so it does not
    accumulate CoW extents that could themselves corrupt on disk failure.
    """
    try:
        if not db_path.exists():
            return
        key = load_key()

        # Use an independent connection (not the thread-local write connection)
        # so the integrity check and backup do not interfere with live writes.
        src = sqlcipher3.connect(str(db_path), isolation_level=None)
        try:
            src.execute(f"PRAGMA key = \"x'{key}'\"")
            result = src.execute("PRAGMA integrity_check").fetchone()
            if not result or str(result[0]).lower() != "ok":
                log.debug("do_healthy_backup: integrity_check not ok — skipping")
                return

            slot1 = db_path.parent / f"{db_path.name}.healthy-1.bak"
            slot2 = db_path.parent / f"{db_path.name}.healthy-2.bak"
            slot3 = db_path.parent / f"{db_path.name}.healthy-3.bak"

            # Data-loss guard. integrity_check proves the DB is STRUCTURALLY sound,
            # but a truncated DB (rows lost without corruption) also passes it — so
            # without this guard a data-loss event silently poisons the healthy
            # slots that recovery later restores from (exactly how ~140 rows were
            # lost once). Refuse to snapshot when a key table dropped sharply vs the
            # most recent good backup; the existing healthy slots are preserved and
            # an alert is emitted. Growth and small deletions are always allowed.
            if slot1.exists():
                cur_counts = _guard_row_counts(src)
                prev_counts: dict[str, int | None] = {}
                try:
                    _prev = sqlcipher3.connect(str(slot1), isolation_level=None)
                    _prev.execute(f"PRAGMA key = \"x'{key}'\"")
                    prev_counts = _guard_row_counts(_prev)
                    _prev.close()
                except Exception:  # noqa: BLE001
                    prev_counts = {}
                for _t in _GUARD_TABLES:
                    _p = prev_counts.get(_t)
                    _c = cur_counts.get(_t)
                    if (_p is not None and _c is not None
                            and _p >= _GUARD_MIN_PREV and _c < _p * _GUARD_DROP_RATIO):
                        _msg = (
                            f"do_healthy_backup: REFUSING snapshot — {_t} dropped "
                            f"{_p}→{_c} (>{int((1-_GUARD_DROP_RATIO)*100)}% loss); "
                            "preserving existing healthy backups"
                        )
                        log.warning(_msg)
                        _emit_recovery_event(
                            "critical", _msg,
                            {"table": _t, "prev": _p, "now": _c},
                        )
                        return

            # Rotate: 2 → 3, 1 → 2, new → 1
            if slot2.exists():
                slot2.replace(slot3)
                _apply_nocow(slot3)
            if slot1.exists():
                slot1.replace(slot2)
                _apply_nocow(slot2)

            dst = sqlcipher3.connect(str(slot1), isolation_level=None)
            try:
                dst.execute(f"PRAGMA key = \"x'{key}'\"")
                src.backup(dst)
            finally:
                dst.close()

            _apply_nocow(slot1)
            log.info("do_healthy_backup: snapshot → %s", slot1.name)
        finally:
            src.close()
    except Exception as exc:  # noqa: BLE001
        log.warning("do_healthy_backup: failed (non-fatal): %s", exc)


def refresh_healthy_backups(reason: str = "manual refresh") -> None:
    """Re-snapshot ALL healthy backup slots from the current DB state.

    Run this right AFTER deleting test/trial data from the real DB: the rotating
    30-min snapshots may have captured the test rows, and a corruption recovery
    inside the rotation window would otherwise RESTORE them — resurrecting data
    that was deliberately deleted (this actually happened once with a stray
    test fact riding a restored backup). Three consecutive snapshots flush every
    slot (1 → 2 → 3), so all recovery candidates reflect the cleaned state.
    """
    log.info("refresh_healthy_backups: flushing all slots (%s)", reason)
    for _ in range(3):
        # Pass DB_PATH explicitly: do_healthy_backup's default was bound at
        # import time, so a swapped DB_PATH (tests) would silently be ignored.
        do_healthy_backup(DB_PATH)


# ─────────────────── self-healing recovery (mid-operation) ───────────────────


def attempt_self_heal() -> bool:
    """Recover from a corruption error detected during a live query.

    Closes the calling thread's broken connection, acquires the inter-process
    recovery lock, runs the full recovery ladder, and stores the new connection
    as the thread-local connection so subsequent calls work immediately.

    Returns True on success, False on failure. Non-raising.

    Callers **must** gate invocation on a session-scoped flag (e.g.
    ``_self_healed`` on ConversationMemory) so recovery is attempted at most
    once per error event — infinite-loop prevention.
    """
    try:
        key = load_key()
        close()  # drop the broken thread-local connection(s)
        with _recovery_lock(DB_PATH):
            new_conn = _repair_corrupt_db_locked(DB_PATH, key)
    except Exception as exc:  # noqa: BLE001
        log.warning("attempt_self_heal: recovery ladder failed: %s", exc)
        return False

    _apply_nocow(DB_PATH)

    try:
        new_conn.execute("PRAGMA journal_mode=TRUNCATE")
        new_conn.execute("PRAGMA foreign_keys=ON")
        new_conn.execute("PRAGMA synchronous=FULL")
        new_conn.execute("PRAGMA busy_timeout=5000")
        new_conn.row_factory = sqlcipher3.Row
        try:
            _load_sqlite_vec(new_conn)
        except Exception:  # noqa: BLE001
            pass
        _tl.conn = new_conn
        log.warning("attempt_self_heal: recovery succeeded — new connection stored")
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("attempt_self_heal: could not configure recovered connection: %s", exc)
        return False
