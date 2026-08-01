"""Encrypted sqlcipher store for the Relationships domain.

Independent key + DB from health/finance per the threat model in P2/P3:
compromising one sensitive domain should not give read access to another.
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

from lifeos._common.migrations import make_raw_capture_migration
from lifeos._common.nocow import ensure_nocow_dir

log = logging.getLogger("lifeos.relationships.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    return Path(os.environ.get("LIFEOS_REL_DB_PATH") or (_default_dir() / "relationships.db"))


def key_path() -> Path:
    return Path(os.environ.get("LIFEOS_REL_KEY_PATH") or (_default_dir() / "relationships.key"))


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
    log.info("generated new relationships encryption key at %s", kp)
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


def _migration_002_people(conn: sqlcipher3.Connection) -> None:
    # First-class people entities. `role` is free-form (esposa, papá, jefe, ...).
    # `color` is a hex color for the UI to avatar-tag interactions per person.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS people (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            role TEXT,
            since TEXT,
            color TEXT,
            notes TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    # Unique on name (case-insensitive) when not deleted — prevents accidental
    # duplicate "María" / "maria" rows from auto-ingestion.
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_people_name_unique "
        "ON people(LOWER(name)) WHERE deleted_at IS NULL"
    )


def _migration_003_interactions(conn: sqlcipher3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS interactions (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,                          -- ISO UTC when it happened
            person_id TEXT NOT NULL REFERENCES people(id),
            kind TEXT NOT NULL,                        -- conversation|conflict|quality_time|call|text|note
            title TEXT NOT NULL,
            body TEXT,
            mood_pre INTEGER,                          -- 1..10
            mood_post INTEGER,                         -- 1..10
            tags TEXT,                                 -- comma-separated
            source TEXT NOT NULL DEFAULT 'manual',
            confidence REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_interactions_person_ts "
        "ON interactions(person_id, ts DESC) WHERE deleted_at IS NULL"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_interactions_ts "
        "ON interactions(ts DESC) WHERE deleted_at IS NULL"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_interactions_kind "
        "ON interactions(kind, ts DESC) WHERE deleted_at IS NULL"
    )


# FOOTGUN: 003 is already taken by _migration_003_interactions.
# Raw-capture for the interactions table is version 004.
_migration_004_raw_capture = make_raw_capture_migration("interactions")


def _migration_005_people_graph(conn: sqlcipher3.Connection) -> None:
    """Birth dates, contact cadence, and links BETWEEN people.

    `birth_date` stores the DATE, never an age: an age is wrong within a year
    and the assistant would state it confidently. `contact_cadence_days` is the
    "talk every six weeks" interval — the due date it implies is computed from
    the last real interaction, never stored, so an unplanned message cannot
    leave a stale schedule behind.

    `person_links` carries friend→wife, friend→child, so a friend's family is
    part of the same picture. Stored ONE row per pair with the kind as seen
    from `from_id`; the inverse is derived on read, which keeps the two
    directions from ever disagreeing.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(people)")}
    if "birth_date" not in cols:
        conn.execute("ALTER TABLE people ADD COLUMN birth_date TEXT")  # ISO date
    if "contact_cadence_days" not in cols:
        conn.execute("ALTER TABLE people ADD COLUMN contact_cadence_days INTEGER")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS person_links (
            from_id    TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            to_id      TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            kind       TEXT NOT NULL,   -- partner|child|parent|sibling|friend|...
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (from_id, to_id)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_person_links_to ON person_links(to_id)"
    )
    # Birthday scans read every person with a date; keep that one index-only.
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_people_birth_date "
        "ON people(birth_date) WHERE birth_date IS NOT NULL AND deleted_at IS NULL"
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_people,
    _migration_003_interactions,
    _migration_004_raw_capture,
    _migration_005_people_graph,
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
