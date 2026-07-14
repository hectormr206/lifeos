"""Encrypted SQLite (sqlcipher) for the health domain.

Layout:
    ~/.local/state/lifeos/health.db   ← encrypted blob (chmod 600 implicitly via dir 700)
    ~/.local/state/lifeos/health.key  ← 32-byte random key, hex-encoded, chmod 600

Security model:
- Encryption-at-rest: the .db file alone is unreadable. `file health.db`
  reports "data", not a SQLite database.
- The key file lives next to the DB by default. This protects against
  scenarios where the DB leaks but the key file does NOT — backups that
  exclude the key, accidental file shares, theft of a backup drive, etc.
- It does NOT protect against an attacker with local file-system access:
  if they can read health.key, they can read health.db. Threat model
  for v1 is "backup hygiene", not "active attacker on the machine".
- Future v1.x: migrate the key to a libsecret/kwallet keyring entry,
  unlock on user login. That gives stronger isolation against forensic
  recovery of a stolen disk.

The key file can be overridden via env vars for tests/migrations:
    LIFEOS_HEALTH_DB_PATH   — alternate DB path
    LIFEOS_HEALTH_KEY_PATH  — alternate key file
"""

from __future__ import annotations

import logging
import os
import secrets
import stat
import threading
from pathlib import Path
from typing import Callable

import sqlcipher3

from lifeos._common.migrations import (
    make_raw_capture_migration,
    make_subject_migration,
)
from lifeos._common.nocow import ensure_nocow_dir

log = logging.getLogger("lifeos.health.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_HEALTH_DB_PATH") or (_default_dir() / "health.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_HEALTH_KEY_PATH") or (_default_dir() / "health.key"))


def _ensure_key() -> str:
    """Read or create the encryption key. Returns the hex-encoded key string.

    First call generates 32 random bytes (`secrets.token_bytes(32)`),
    persists them hex-encoded, and tightens permissions. Subsequent calls
    just read.
    """
    kp = key_path()
    kp.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if kp.exists():
        return kp.read_text().strip()
    key = secrets.token_bytes(32).hex()
    kp.write_text(key)
    try:
        kp.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 600
    except Exception:  # noqa: BLE001
        pass
    log.info("generated new health encryption key at %s", kp)
    return key


def connect() -> sqlcipher3.Connection:
    """Open an encrypted connection to the health DB.

    Each call returns a fresh connection — sqlcipher3 connections are not
    thread-safe by default and pooling adds complexity. Connections are
    cheap; if we ever measure overhead, switch to a thread-local cache.
    """
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    ensure_nocow_dir(p.parent)
    key = _ensure_key()
    conn = sqlcipher3.connect(p, isolation_level=None, check_same_thread=False)
    # Hex key must be quoted with the special "x'...'" syntax in PRAGMA key.
    # sqlcipher3 accepts the raw hex via a parameter binding too.
    conn.execute(f"PRAGMA key = \"x'{key}'\"")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    # Tighten permissions on first write — the journal/wal files inherit.
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


def _migration_002_health_entries(conn: sqlcipher3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS health_entries (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,                          -- ISO UTC, when it happened
            kind TEXT NOT NULL,                        -- symptom|medication|vital|condition|note
            title TEXT NOT NULL,
            body TEXT,
            data TEXT,                                 -- kind-specific JSON
            tags TEXT,                                 -- comma-separated
            source TEXT NOT NULL DEFAULT 'manual',     -- manual|chat|voice
            confidence REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_health_kind_ts "
        "ON health_entries(kind, ts DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_health_ts "
        "ON health_entries(ts DESC) WHERE deleted_at IS NULL"
    )


_migration_003_raw_capture = make_raw_capture_migration("health_entries")
_migration_004_subject = make_subject_migration("health_entries")

MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_health_entries,
    _migration_003_raw_capture,
    _migration_004_subject,
]


def apply_migrations(conn: sqlcipher3.Connection | None = None) -> int:
    """Bring the encrypted DB to the latest schema. Idempotent."""
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
                conn.execute(
                    "INSERT INTO schema_version(version) VALUES (?)", (idx,)
                )
            row = conn.execute(
                "SELECT MAX(version) FROM schema_version"
            ).fetchone()
            return int(row[0] or 0)
    finally:
        if own_conn:
            conn.close()
