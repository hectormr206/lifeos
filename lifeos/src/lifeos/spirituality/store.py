"""Encrypted sqlcipher store for the Spirituality domain."""

from __future__ import annotations

import logging
import os
import secrets
import stat
import threading
from pathlib import Path
from typing import Callable

import sqlcipher3

log = logging.getLogger("lifeos.spirituality.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_SPIRIT_DB_PATH") or (_default_dir() / "spirituality.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_SPIRIT_KEY_PATH") or (_default_dir() / "spirituality.key"))


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
    log.info("generated new spirituality encryption key at %s", kp)
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


def _migration_002_entries(conn: sqlcipher3.Connection) -> None:
    # kinds: reflection|gratitude|meditation|value|retro|question
    # data JSON is kind-specific (e.g. gratitude can store the discrete
    # items list, retro can store wins/losses/next_focus).
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS spirituality_entries (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,                          -- ISO UTC when it happened
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT,                                 -- main free-form text
            mood INTEGER,                              -- 1..10 optional
            data TEXT,                                 -- kind-specific JSON
            tags TEXT,                                 -- comma-separated
            source TEXT NOT NULL DEFAULT 'manual',
            confidence REAL NOT NULL DEFAULT 1.0,
            reminder_id TEXT,                          -- optional FK to lifeos.reminders (weekly retro)
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_spirit_kind_ts "
        "ON spirituality_entries(kind, ts DESC) WHERE deleted_at IS NULL"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_spirit_ts "
        "ON spirituality_entries(ts DESC) WHERE deleted_at IS NULL"
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_entries,
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
