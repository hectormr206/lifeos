"""Shared migration helpers for domain stores.

These helpers produce Migration callables that can be appended to any store's
MIGRATIONS list. Each helper is idempotent (PRAGMA guard) so running
apply_migrations more than once is safe.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import sqlcipher3


def make_raw_capture_migration(table: str):
    """Return a Migration that adds nullable raw_utterance + source_conv_id
    columns to *table*. Additive, idempotent, backward-compatible.

    SQLite ALTER ADD COLUMN is O(1) metadata-only; existing rows read NULL.
    The PRAGMA guard prevents duplicate-column errors on re-runs.

    Usage::

        from lifeos._common.migrations import make_raw_capture_migration

        _migration_003_raw_capture = make_raw_capture_migration("health_entries")
        MIGRATIONS = [..., _migration_003_raw_capture]
    """
    def _migrate(conn: "sqlcipher3.Connection") -> None:
        cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
        if "raw_utterance" not in cols:
            conn.execute(
                f"ALTER TABLE {table} ADD COLUMN raw_utterance TEXT"
            )
        if "source_conv_id" not in cols:
            conn.execute(
                f"ALTER TABLE {table} ADD COLUMN source_conv_id INTEGER"
            )

    _migrate.__name__ = f"_migration_raw_capture_{table}"
    return _migrate
