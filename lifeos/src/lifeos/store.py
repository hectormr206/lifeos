"""Encrypted SQLite (sqlcipher3) store with versioned schema migrations.

Layout:
    ~/.local/state/lifeos/lifeos.db   ← encrypted blob
    ~/.local/state/lifeos/lifeos.key  ← 32-byte random key, hex-encoded, chmod 600

The key file can be overridden via env vars for tests/migrations:
    LIFEOS_DB_PATH   — alternate DB path
    LIFEOS_KEY_PATH  — alternate key file path (takes priority over LIFEOS_STATE_DIR)

Each module owns its tables but shares this connection helper so the
scheduler's jobstore and the reminders DAO see the same DB.

Migrations are append-only: each version is a function that takes a connection
and brings the schema from version N-1 to N. The `schema_version` table
tracks which migrations have run; `apply_migrations()` is idempotent.
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

from lifeos._common.nocow import ensure_nocow_dir

log = logging.getLogger("lifeos.store")

_lock = threading.Lock()


def _default_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )


def db_path() -> Path:
    """Return the active DB path. Honors LIFEOS_DB_PATH for tests."""
    override = os.environ.get("LIFEOS_DB_PATH")
    return Path(override) if override else (_default_dir() / "lifeos.db")


def key_path() -> Path:
    """Return the active key file path. Honors LIFEOS_KEY_PATH for tests."""
    override = os.environ.get("LIFEOS_KEY_PATH")
    return Path(override) if override else (_default_dir() / "lifeos.key")


def load_key() -> str:
    """Read or generate the encryption key. Returns the hex-encoded key string.

    First call generates 32 random bytes, persists them hex-encoded, and
    tightens permissions to 600. Subsequent calls just read the file.
    Per-process caching is acceptable — key rotation requires restart.
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
    log.info("generated new lifeos encryption key at %s", kp)
    return key


def connect() -> sqlcipher3.Connection:
    """Open an encrypted connection to the LifeOS DB. Ensures parent dir exists.

    Each call returns a fresh connection — sqlcipher3 connections are not
    thread-safe by default. Connections are cheap; pool if overhead is measured.

    The PRAGMA key must be applied IMMEDIATELY after connect(), before any
    other query, or sqlcipher3 treats the file as unkeyed.
    """
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    ensure_nocow_dir(p.parent)
    key = load_key()
    conn = sqlcipher3.connect(p, isolation_level=None, check_same_thread=False)
    # Hex key must use the special "x'...'" syntax in PRAGMA key.
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


def _migration_002_reminders(conn: sqlcipher3.Connection) -> None:
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


def _migration_003_push_subscriptions(conn: sqlcipher3.Connection) -> None:
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


def _migration_004_reminders_recurrence(conn: sqlcipher3.Connection) -> None:
    # Recurring reminders: cron string ("0 9 * * *" = daily at 9am).
    # NULL → one-shot (current behavior preserved). `last_fired_at` is the
    # most recent fire time; for one-shot it equals `fired_at`.
    cols = {row[1] for row in conn.execute("PRAGMA table_info(reminders)").fetchall()}
    if "recurrence" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN recurrence TEXT")
    if "last_fired_at" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN last_fired_at TEXT")


def _migration_006_edges(conn: sqlcipher3.Connection) -> None:
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


def _migration_005_reminder_end_conditions(conn: sqlcipher3.Connection) -> None:
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


def _migration_008_notif_log(conn: sqlcipher3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS notif_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sent_at TEXT NOT NULL DEFAULT (datetime('now')),
            hash TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'ambient',
            outcome TEXT NOT NULL DEFAULT 'sent'
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_notif_log_sent_at "
        "ON notif_log(sent_at DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_notif_log_hash_sent_at "
        "ON notif_log(hash, sent_at DESC)"
    )


def _migration_007_fastpath_metrics(conn: sqlcipher3.Connection) -> None:
    # Instrumentation for the chat fast-path. Records ONLY metadata
    # (which stage handled the call, latency, input size) — NEVER the
    # text content itself. That keeps this table OK to live in the
    # encrypted core DB. The text stays in the per-domain encrypted
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


def _migration_009_reminder_actions(conn: sqlcipher3.Connection) -> None:
    # Agentic reminders (Briefings). A reminder can carry an `action_prompt`
    # that, when it fires, runs through the brain with web-search tools and
    # produces a curated digest stored back on the row. The push notification
    # then deep-links to that reminder's card in the Briefings dashboard.
    # - action_kind: 'message' (current behavior) | 'agentic'
    # - action_prompt: the natural-language task to run on each fire
    # - last_result: latest rendered markdown (overwritten each run)
    # - last_result_at: ISO8601 UTC timestamp of the latest run
    # - last_result_meta: JSON of structured items so the card can render
    #   title/summary/url per item.
    cols = {row[1] for row in conn.execute("PRAGMA table_info(reminders)").fetchall()}
    if "action_kind" not in cols:
        conn.execute(
            "ALTER TABLE reminders ADD COLUMN action_kind TEXT DEFAULT 'message'"
        )
    if "action_prompt" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN action_prompt TEXT")
    if "last_result" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN last_result TEXT")
    if "last_result_at" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN last_result_at TEXT")
    if "last_result_meta" not in cols:
        conn.execute("ALTER TABLE reminders ADD COLUMN last_result_meta TEXT")


def _migration_010_schedule_cache(conn: sqlcipher3.Connection) -> None:
    # Learned schedule-parse cache + miss log. When the deterministic regex
    # parsers miss but the 4B LLM fallback succeeds on a RECURRING task, we
    # cache (normalized phrasing → stable schedule) so the same/near phrasing
    # next time is resolved by an instant DB lookup instead of re-invoking the
    # 4B. Only recurring parses are cached (recurrence is the cron and is always
    # present). One-shot (relative-time) intents are never cached.
    #
    # `schedule_miss_log` records every "regex-missed → 4B" event for later
    # HUMAN-reviewed regex improvement. It is DATA only — nothing here ever
    # auto-modifies regex or code.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schedule_cache (
            norm_text TEXT PRIMARY KEY,
            kind TEXT,
            recurrence TEXT NOT NULL,
            content TEXT,
            hits INTEGER DEFAULT 0,
            created_at TEXT,
            last_used_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schedule_miss_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            raw_text TEXT,
            norm_text TEXT,
            resolved INTEGER,
            kind TEXT,
            recurrence TEXT,
            created_at TEXT
        )
        """
    )


MIGRATIONS: list[Migration] = [
    _migration_001_schema_version,
    _migration_002_reminders,
    _migration_003_push_subscriptions,
    _migration_004_reminders_recurrence,
    _migration_005_reminder_end_conditions,
    _migration_006_edges,
    _migration_007_fastpath_metrics,
    _migration_008_notif_log,
    _migration_009_reminder_actions,
    _migration_010_schedule_cache,
]


# Wall-clock timestamp expression matching the rest of the store (UTC, ISO8601).
_NOW_TS = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"


def schedule_cache_get(norm_text: str) -> dict | None:
    """Return the cached {kind, recurrence, content} for `norm_text`, or None.

    On a hit, increments `hits` and updates `last_used_at`. Never raises — a
    cache failure must never break reminder creation, so errors are logged and
    None is returned.
    """
    try:
        with connect() as conn:
            row = conn.execute(
                "SELECT kind, recurrence, content FROM schedule_cache "
                "WHERE norm_text = ?",
                (norm_text,),
            ).fetchone()
            if row is None:
                return None
            conn.execute(
                f"UPDATE schedule_cache SET hits = hits + 1, last_used_at = {_NOW_TS} "
                "WHERE norm_text = ?",
                (norm_text,),
            )
            return {
                "kind": row["kind"],
                "recurrence": row["recurrence"],
                "content": row["content"],
            }
    except Exception:  # noqa: BLE001
        log.warning("schedule_cache_get failed for %r", norm_text, exc_info=True)
        return None


def schedule_cache_put(
    norm_text: str, *, kind: str, recurrence: str, content: str | None
) -> None:
    """Upsert a learned (norm_text → schedule) cache row. Never raises.

    `created_at` is set on first insert and preserved on update; `hits` is
    preserved across updates. Only RECURRING parses are cached, so `recurrence`
    (the cron) is always present.
    """
    try:
        with connect() as conn:
            conn.execute(
                "INSERT INTO schedule_cache "
                "(norm_text, kind, recurrence, content, hits, created_at, last_used_at) "
                f"VALUES (?, ?, ?, ?, 0, {_NOW_TS}, {_NOW_TS}) "
                "ON CONFLICT(norm_text) DO UPDATE SET "
                "kind = excluded.kind, recurrence = excluded.recurrence, "
                f"content = excluded.content, last_used_at = {_NOW_TS}",
                (norm_text, kind, recurrence, content),
            )
    except Exception:  # noqa: BLE001
        log.warning("schedule_cache_put failed for %r", norm_text, exc_info=True)


def schedule_miss_log_add(
    *,
    raw_text: str,
    norm_text: str,
    resolved: bool,
    kind: str | None,
    recurrence: str | None,
) -> None:
    """Append a "regex-missed → 4B" event to the miss log. Never raises.

    Kept bounded: after each insert, rows beyond the most recent 1000 are
    pruned (a simple cap). DATA only — for later human-reviewed regex work.
    """
    try:
        with connect() as conn:
            conn.execute(
                "INSERT INTO schedule_miss_log "
                "(raw_text, norm_text, resolved, kind, recurrence, created_at) "
                f"VALUES (?, ?, ?, ?, ?, {_NOW_TS})",
                (raw_text, norm_text, 1 if resolved else 0, kind, recurrence),
            )
            conn.execute(
                "DELETE FROM schedule_miss_log WHERE id NOT IN "
                "(SELECT id FROM schedule_miss_log ORDER BY id DESC LIMIT 1000)"
            )
    except Exception:  # noqa: BLE001
        log.warning("schedule_miss_log_add failed for %r", raw_text, exc_info=True)


def apply_migrations(conn: sqlcipher3.Connection | None = None) -> int:
    """Bring the encrypted DB to the latest schema. Returns the resulting version.

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
