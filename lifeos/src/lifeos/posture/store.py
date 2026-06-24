"""Encrypted sqlcipher store for the Posture domain."""

from __future__ import annotations

import logging
import os
import secrets
import stat
import threading
from pathlib import Path
from typing import Callable

import sqlcipher3

from lifeos._common.nocow import ensure_nocow_dir

log = logging.getLogger("lifeos.posture.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_POSTURE_DB_PATH") or (_default_dir() / "posture.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_POSTURE_KEY_PATH") or (_default_dir() / "posture.key"))


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
    log.info("generated new posture encryption key at %s", kp)
    return key


def connect() -> sqlcipher3.Connection:
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    ensure_nocow_dir(p.parent)
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


def _migration_002_scans(conn: sqlcipher3.Connection) -> None:
    # Frames are NEVER persisted — we only store the classification result.
    # `nudge_sent=1` means a push notification was dispatched because the
    # state was problematic and confidence cleared the threshold.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS posture_scans (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,
            state TEXT NOT NULL,                   -- good|slouched|forward_head|leaning|not_at_desk|face_not_visible|error
            confidence REAL NOT NULL DEFAULT 0,    -- 0..1
            suggestion TEXT,                       -- LLM-produced suggestion text
            nudge_sent INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'scheduled',  -- scheduled|manual
            raw_response TEXT,                     -- raw brain output for debugging
            error TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_posture_ts "
        "ON posture_scans(ts DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_posture_nudge_ts "
        "ON posture_scans(nudge_sent, ts DESC)"
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_scans,
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
