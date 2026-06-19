"""Tests for the shared make_raw_capture_migration helper.

Covers:
- fresh DB: both columns present after migration
- existing-DB upgrade: columns added without touching existing rows
- idempotency: running migration twice does not error

Tables under test for PR 1a: health_entries, finance_entries, exercise_sessions.
"""

from __future__ import annotations

import pytest
from pathlib import Path


# --------------------------------------------------------------------------- #
# Fixtures — one isolated environment per store so the tests can run in
# parallel without key / db path collisions.
# --------------------------------------------------------------------------- #


@pytest.fixture()
def health_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos.health import store
    store.apply_migrations()
    return store


@pytest.fixture()
def finance_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    from lifeos.finance import store
    store.apply_migrations()
    return store


@pytest.fixture()
def exercise_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "exercise.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "exercise.key"))
    from lifeos.exercise import store
    store.apply_migrations()
    return store


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _column_names(store_module, table: str) -> set[str]:
    with store_module.connect() as conn:
        rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {r[1] for r in rows}


# --------------------------------------------------------------------------- #
# Scenario: "Migration on fresh database"
# Both columns exist immediately after apply_migrations on a new DB.
# --------------------------------------------------------------------------- #


def test_fresh_db_health_has_raw_capture_columns(health_db) -> None:
    cols = _column_names(health_db, "health_entries")
    assert "raw_utterance" in cols, f"raw_utterance missing from health_entries; cols={cols}"
    assert "source_conv_id" in cols, f"source_conv_id missing from health_entries; cols={cols}"


def test_fresh_db_finance_has_raw_capture_columns(finance_db) -> None:
    cols = _column_names(finance_db, "finance_entries")
    assert "raw_utterance" in cols
    assert "source_conv_id" in cols


def test_fresh_db_exercise_has_raw_capture_columns(exercise_db) -> None:
    cols = _column_names(exercise_db, "exercise_sessions")
    assert "raw_utterance" in cols
    assert "source_conv_id" in cols


# --------------------------------------------------------------------------- #
# Scenario: "Migration on existing database"
# Existing rows get NULL for both new columns; table remains queryable.
# --------------------------------------------------------------------------- #


def test_existing_health_rows_get_null_after_migration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Simulate an older DB (migration 002 only) that gets upgraded to 003."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))

    from lifeos.health import store

    # Apply only migrations 001 + 002 (no 003 yet).
    with store.connect() as conn:
        store.MIGRATIONS[0](conn)   # schema_version table
        store.MIGRATIONS[1](conn)   # health_entries table
        conn.execute("INSERT INTO schema_version(version) VALUES (1)")
        conn.execute("INSERT INTO schema_version(version) VALUES (2)")
        # Insert a pre-existing row without raw_utterance
        conn.execute(
            "INSERT INTO health_entries(id, ts, kind, title, source, confidence) "
            "VALUES ('old-id', '2026-01-01T00:00:00Z', 'note', 'old row', 'manual', 1.0)"
        )

    # Now apply the full migration stack (should add migration 003).
    store.apply_migrations()

    # Existing row must have NULL for both new columns.
    with store.connect() as conn:
        row = conn.execute(
            "SELECT raw_utterance, source_conv_id FROM health_entries WHERE id = 'old-id'"
        ).fetchone()
    assert row is not None
    assert row[0] is None, "raw_utterance should be NULL for pre-existing rows"
    assert row[1] is None, "source_conv_id should be NULL for pre-existing rows"


def test_migration_idempotent_health(health_db) -> None:
    """Running apply_migrations twice must not error or duplicate columns."""
    health_db.apply_migrations()  # second call
    cols = _column_names(health_db, "health_entries")
    assert "raw_utterance" in cols
    assert "source_conv_id" in cols
