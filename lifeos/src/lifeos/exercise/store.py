"""Encrypted sqlcipher store for the Exercise domain."""

from __future__ import annotations

import logging
import os
import secrets
import stat
import threading
from pathlib import Path
from typing import Callable

import sqlcipher3

from lifeos._common.migrations import make_raw_capture_migration

log = logging.getLogger("lifeos.exercise.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_EXERCISE_DB_PATH") or (_default_dir() / "exercise.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_EXERCISE_KEY_PATH") or (_default_dir() / "exercise.key"))


def _ensure_key() -> str:
    kp = key_path()
    kp.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if kp.exists():
        return kp.read_text().strip()
    key = secrets.token_bytes(32).hex()
    kp.write_text(key)
    try:
        kp.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except Exception:  # noqa: BLE001
        pass
    log.info("generated new exercise encryption key at %s", kp)
    return key


def connect() -> sqlcipher3.Connection:
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = _ensure_key()
    conn = sqlcipher3.connect(p, isolation_level=None, check_same_thread=False)
    conn.execute(f"PRAGMA key = \"x'{key}'\"")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        p.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except Exception:  # noqa: BLE001
        pass
    conn.row_factory = sqlcipher3.Row
    return conn


Migration = Callable[[sqlcipher3.Connection], None]


def _migration_001_schema_version(conn: sqlcipher3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )


def _migration_002_sessions(conn: sqlcipher3.Connection) -> None:
    # kinds: walk|run|cardio|strength|yoga|sports|other
    # data is JSON for kind-specific fields (distance_km, reps, splits, ...).
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS exercise_sessions (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,                          -- ISO UTC when the session happened
            kind TEXT NOT NULL,
            duration_minutes INTEGER NOT NULL DEFAULT 0,
            intensity INTEGER,                         -- 1..10 optional
            mood_pre INTEGER,                          -- 1..10 optional
            mood_post INTEGER,                         -- 1..10 optional
            location TEXT,                             -- outdoor|gym|home|... free-form
            title TEXT NOT NULL,
            body TEXT,
            data TEXT,                                 -- JSON, kind-specific
            tags TEXT,                                 -- comma-separated
            source TEXT NOT NULL DEFAULT 'manual',
            confidence REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_exercise_kind_ts "
        "ON exercise_sessions(kind, ts DESC) WHERE deleted_at IS NULL"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_exercise_ts "
        "ON exercise_sessions(ts DESC) WHERE deleted_at IS NULL"
    )


_migration_003_raw_capture = make_raw_capture_migration("exercise_sessions")

MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_sessions,
    _migration_003_raw_capture,
]


def apply_migrations(conn: sqlcipher3.Connection | None = None) -> int:
    own_conn = conn is None
    if own_conn:
        conn = connect()
    try:
        with _lock:
            MIGRATIONS[0](conn)
            applied = {
                r[0]
                for r in conn.execute("SELECT version FROM schema_version").fetchall()
            }
            for idx, mig in enumerate(MIGRATIONS, start=1):
                if idx in applied:
                    continue
                mig(conn)
                conn.execute("INSERT INTO schema_version(version) VALUES (?)", (idx,))
            row = conn.execute("SELECT MAX(version) FROM schema_version").fetchone()
            return int(row[0] or 0)
    finally:
        if own_conn:
            conn.close()
