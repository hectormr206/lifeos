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
        # Event-date column: stores the real event timestamp (vs. insertion time).
        migrate_nodes_occurred_at()
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
    now = time.time()
    payload = json.dumps(data or {}, ensure_ascii=False)
    tz = _current_tz()
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, created_tz, occurred_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (kind, label, payload, domain, now, now, tz, occurred_at),
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


def delete_node(node_id: int) -> bool:
    """Delete a node and everything attached to it.

    Removes the node plus ALL its edges (from_id or to_id), and its
    nodes_fts / vec_nodes rows if present. Returns True if a node row was
    deleted, False otherwise.

    SAFETY: refuses to delete the user-hub node (data role=user) — you cannot
    delete "yourself". Returns False in that case without touching anything.

    Defensive: never raises; returns False on bad input or any error.
    """
    try:
        nid = int(node_id)
    except (TypeError, ValueError):
        return False
    c = _connect()
    row = c.execute("SELECT data FROM nodes WHERE id = ?", (nid,)).fetchone()
    if row is None:
        return False
    # Hub guard: never delete the user's own anchor node.
    try:
        if json.loads(row["data"] or "{}").get("role") == "user":
            log.warning("delete_node refused: node %d is the user hub", nid)
            return False
    except (ValueError, TypeError):
        pass
    try:
        with _tx() as tx:
            tx.execute("DELETE FROM edges WHERE from_id = ? OR to_id = ?", (nid, nid))
            tx.execute("DELETE FROM nodes_fts WHERE rowid = ?", (nid,))
            # vec_nodes may not exist / sqlite-vec may be unloaded — best-effort.
            try:
                tx.execute("DELETE FROM vec_nodes WHERE node_id = ?", (nid,))
            except Exception:  # noqa: BLE001
                pass
            cur = tx.execute("DELETE FROM nodes WHERE id = ?", (nid,))
        return cur.rowcount > 0
    except Exception:  # noqa: BLE001
        log.warning("delete_node failed for %d", nid, exc_info=True)
        return False


def delete_edge(edge_id: int) -> bool:
    """Delete one edge by id. Returns True if a row was removed.

    Defensive: never raises; returns False on bad input or any error.
    """
    try:
        eid = int(edge_id)
    except (TypeError, ValueError):
        return False
    try:
        with _tx() as tx:
            cur = tx.execute("DELETE FROM edges WHERE id = ?", (eid,))
        return cur.rowcount > 0
    except Exception:  # noqa: BLE001
        log.warning("delete_edge failed for %d", eid, exc_info=True)
        return False


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


def same_day_neighbors(node_id: int, conn=None) -> list[dict[str, Any]]:
    """Return all nodes connected to node_id via a 'same-day' edge in EITHER direction.

    Uses a UNION of two direction-specific queries so SQLite can use the
    dedicated idx_edges_from and idx_edges_to indexes instead of a full
    OR-scan.  Self (n.id = node_id) is excluded in both arms.

    Returns a list of node dicts (id, kind, label, domain, created_at,
    occurred_at).  Returns [] on any error.
    """
    c = conn or _connect()
    try:
        rows = c.execute(
            """
            SELECT n.id, n.kind, n.label, n.domain, n.created_at, n.occurred_at
            FROM nodes n
            JOIN edges e ON e.from_id = ? AND e.to_id = n.id AND e.kind = 'same-day'
            WHERE n.id != ?
            UNION
            SELECT n.id, n.kind, n.label, n.domain, n.created_at, n.occurred_at
            FROM nodes n
            JOIN edges e ON e.to_id = ? AND e.from_id = n.id AND e.kind = 'same-day'
            WHERE n.id != ?
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
            "SELECT id FROM nodes WHERE kind='fact' AND label=? LIMIT 1", (label,)
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
            "SELECT id, kind, label, domain, created_at, occurred_at FROM nodes "
            "WHERE kind = 'fact' AND COALESCE(occurred_at, created_at) >= ? "
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
    with _tx() as c:
        cur = c.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, session_id, has_screenshot, source) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (time.time(), user_text, axi_text, session_id, int(has_screenshot), source),
        )
        return cur.lastrowid


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
    """
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


def run_periodic_embed_drain(*, embed_limit: int = 50, similarity_threshold: float = 0.85) -> None:
    """Drain pending embeddings, backfill similar-to edges, and run auto-linkers.

    Intended to be called periodically (e.g. every 5 minutes) from the dashboard
    lifespan background task.  All operations are idempotent and bounded.

    row_factory is set to sqlcipher3.Row before run_auto_linkers so the linker
    dict-access (row["col"]) works correctly regardless of caller state.
    """
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
        f"SELECT id, kind, label, domain, created_at, occurred_at FROM nodes WHERE id IN ({placeholders})",
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
