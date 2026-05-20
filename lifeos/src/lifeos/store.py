"""SQLite store with versioned schema migrations.

One database lives at `~/.local/state/lifeos/lifeos.db` (override via
`LIFEOS_DB_PATH`). Each module owns its tables but shares this connection
helper so the scheduler's jobstore and the reminders DAO see the same DB.

Migrations are append-only: each version is a function that takes a connection
and brings the schema from version N-1 to N. The `schema_version` table
tracks which migrations have run; `apply_migrations()` is idempotent.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from pathlib import Path
from typing import Callable

_DEFAULT_DB = Path.home() / ".local" / "state" / "lifeos" / "lifeos.db"

_lock = threading.Lock()


def db_path() -> Path:
    """Return the active DB path. Honors LIFEOS_DB_PATH for tests."""
    override = os.environ.get("LIFEOS_DB_PATH")
    return Path(override) if override else _DEFAULT_DB


def connect() -> sqlite3.Connection:
    """Open a connection to the LifeOS DB. Ensures parent dir exists.

    Connections are NOT cached. SQLite is happy with many short connections,
    and this keeps multi-threaded use simple (each caller gets its own).
    """
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    conn = sqlite3.connect(p, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


Migration = Callable[[sqlite3.Connection], None]


def _migration_001_schema_version(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )


def _migration_002_reminders(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS reminders (
            id TEXT PRIMARY KEY,
            when_ts TEXT NOT NULL,                    -- ISO8601 UTC
            message TEXT NOT NULL,
            channel TEXT NOT NULL DEFAULT 'push',     -- push | log | (future: email/sms)
            status TEXT NOT NULL DEFAULT 'pending',   -- pending | fired | cancelled | failed
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            fired_at TEXT,
            error TEXT
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_reminders_status_when "
        "ON reminders(status, when_ts)"
    )


def _migration_003_push_subscriptions(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS push_subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT NOT NULL UNIQUE,
            p256dh TEXT NOT NULL,
            auth TEXT NOT NULL,
            user_agent TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )


def _migration_004_reminders_recurrence(conn: sqlite3.Connection) -> None:
    # Recurring reminders: cron string ("0 9 * * *" = daily at 9am).
    # NULL → one-shot (current behavior preserved). `last_fired_at` is the
    # most recent fire time; for one-shot it equals `fired_at`.
    cols = {row[1] for row in conn.execute("PRAGMA table_info(reminders)").fetchall()}
    if "recurrence" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN recurrence TEXT")
    if "last_fired_at" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN last_fired_at TEXT")


def _migration_006_edges(conn: sqlite3.Connection) -> None:
    # Cross-domain graph edges. The actual entries live in their respective
    # (encrypted) per-domain DBs; this table only holds ulids + relation
    # vocabulary, which on its own discloses nothing useful. The benefit
    # of co-locating edges here is that the graph layer can query without
    # decrypting any sensitive store unless the caller actually needs the
    # destination entry's content.
    #
    # Controlled vocabulary for `rel` (extended as needed):
    #   - caused-by         A was caused by B (effect → cause)
    #   - precedes          A happened before B in a meaningful sequence
    #   - same-event        A and B describe the same real-world event
    #   - mentions-person   A mentions person B (people: TODO)
    #   - resolved-by       A (problem) was resolved by B (intervention)
    #   - pattern-of        A is one instance of recurring pattern B
    #   - triggered-by      A was triggered by B
    #   - funded            B funded A (savings → purchase)
    #   - costs             A costs B (e.g. recurring expense vs entry)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS edges (
            id TEXT PRIMARY KEY,
            src_id TEXT NOT NULL,
            src_domain TEXT NOT NULL,
            dst_id TEXT NOT NULL,
            dst_domain TEXT NOT NULL,
            rel TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            metadata TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            created_by TEXT NOT NULL DEFAULT 'system'
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_edges_src "
        "ON edges(src_domain, src_id, rel)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_edges_dst "
        "ON edges(dst_domain, dst_id, rel)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_edges_rel "
        "ON edges(rel)"
    )


def _migration_005_reminder_end_conditions(conn: sqlite3.Connection) -> None:
    # End conditions for recurring reminders (Google-Calendar style "Finaliza"):
    # - ends_at: ISO UTC timestamp. Scheduler stops firing after this instant.
    # - occurrences_left: integer countdown. Decrements on each fire; when 0,
    #   the reminder is cancelled and removed from the scheduler.
    # NULL on both → fire forever.
    cols = {row[1] for row in conn.execute("PRAGMA table_info(reminders)").fetchall()}
    if "ends_at" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN ends_at TEXT")
    if "occurrences_left" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN occurrences_left INTEGER")


def _migration_007_fastpath_metrics(conn: sqlite3.Connection) -> None:
    # Instrumentation for the chat fast-path. Records ONLY metadata
    # (which stage handled the call, latency, input size) — NEVER the
    # text content itself. That keeps this table OK to live in the
    # unencrypted core DB. The text stays in the per-domain encrypted
    # stores (or in the brain's chat memory, also unencrypted today).
    #
    # Used to answer: "what % of chat calls fall through to the brain,
    # and what's the latency cost?" before deciding to build nano-agents.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS fastpath_metrics (
            id TEXT PRIMARY KEY,
            ts TEXT NOT NULL,
            stage TEXT NOT NULL,                   -- which branch handled the call
            latency_ms INTEGER NOT NULL,
            text_length INTEGER NOT NULL DEFAULT 0,
            has_image INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_fastpath_ts "
        "ON fastpath_metrics(ts DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_fastpath_stage_ts "
        "ON fastpath_metrics(stage, ts DESC)"
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_reminders,
    _migration_003_push_subscriptions,
    _migration_004_reminders_recurrence,
    _migration_005_reminder_end_conditions,
    _migration_006_edges,
    _migration_007_fastpath_metrics,
]


def apply_migrations(conn: sqlite3.Connection | None = None) -> int:
    """Bring the DB to the latest schema. Returns the resulting version.

    Idempotent — safe to call on every startup. Acquires a process-wide lock
    so concurrent first-runs (rare but possible during tests) don't both try
    to apply the same migration.
    """
    own_conn = conn is None
    if own_conn:
        conn = connect()
    try:
        with _lock:
            MIGRATIONS[0](conn)  # bootstrap schema_version table
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
