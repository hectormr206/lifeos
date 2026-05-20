"""Encrypted SQLite (sqlcipher) for the finance domain.

Same threat model and pattern as `lifeos.health.store`:
    ~/.local/state/lifeos/finance.db   ← encrypted (sqlcipher)
    ~/.local/state/lifeos/finance.key  ← 32-byte hex key, chmod 600

Independent from the health key/DB on purpose: compromising one domain
should not give read access to the other.
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

log = logging.getLogger("lifeos.finance.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_FINANCE_DB_PATH") or (_default_dir() / "finance.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_FINANCE_KEY_PATH") or (_default_dir() / "finance.key"))


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
    log.info("generated new finance encryption key at %s", kp)
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


def _migration_002_finance_entries(conn: sqlcipher3.Connection) -> None:
    # Amount is always non-negative; `kind` determines direction.
    # Outflow:  expense, debt_payment, big_purchase
    # Inflow:   income, savings, transfer  (transfer to savings increases savings)
    # `reflect_at` is set on big_purchase entries (+7d by default). When the
    # user opens /finance after that timestamp and the entry is unreflected,
    # the UI nudges them to tag it impulsive/planned (`reflection_done=1`).
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS finance_entries (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,                          -- ISO UTC when it happened
            kind TEXT NOT NULL,                        -- expense|income|savings|debt_payment|big_purchase|note
            amount REAL NOT NULL DEFAULT 0,
            currency TEXT NOT NULL DEFAULT 'MXN',
            category TEXT,                             -- food|transport|housing|...
            merchant TEXT,
            title TEXT NOT NULL,
            body TEXT,
            tags TEXT,                                 -- comma-separated (impulsive|planned|recurring|...)
            source TEXT NOT NULL DEFAULT 'manual',
            confidence REAL NOT NULL DEFAULT 1.0,
            reflect_at TEXT,                           -- ISO UTC; NULL = no reflection scheduled
            reflection_done INTEGER NOT NULL DEFAULT 0,
            reminder_id TEXT,                          -- link to lifeos.reminders row that fires the reflection
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_finance_kind_ts "
        "ON finance_entries(kind, ts DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_finance_ts "
        "ON finance_entries(ts DESC) WHERE deleted_at IS NULL"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_finance_reflect_pending "
        "ON finance_entries(reflect_at) "
        "WHERE deleted_at IS NULL AND reflect_at IS NOT NULL AND reflection_done = 0"
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_finance_entries,
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
