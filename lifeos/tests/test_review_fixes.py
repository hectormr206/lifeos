"""Tests for the dual-adversarial-review fixes (lifeos side).

Covers:
  FIX 3  — events: raw_utterance/source_conv_id columns + undo via events deleter
  FIX 3  — events store: raw_capture migration
  "Also" — migration upgrade-path for learning, spirituality, relationships 003→004
  "Also" — raw_utterance stores VERBATIM original text
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


# ─────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────

@pytest.fixture()
def events_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", str(tmp_path / "events.db"))
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", str(tmp_path / "events.key"))
    from lifeos.events import store
    store.apply_migrations()
    return store


@pytest.fixture()
def learning_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learning.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learning.key"))
    from lifeos.learning import store
    store.apply_migrations()
    return store


@pytest.fixture()
def spirituality_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit.key"))
    from lifeos.spirituality import store
    store.apply_migrations()
    return store


@pytest.fixture()
def rel_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    from lifeos.relationships import store
    store.apply_migrations()
    return store


# ─────────────────────────────────────────────────────────────────
# FIX 3 — events raw_utterance columns
# ─────────────────────────────────────────────────────────────────

class TestEventsRawCapture:
    """events store and entries must support raw_utterance / source_conv_id."""

    def test_events_store_has_raw_capture_columns(self, events_db) -> None:
        with events_db.connect() as conn:
            cols = {r[1] for r in conn.execute("PRAGMA table_info(events)").fetchall()}
        assert "raw_utterance" in cols, f"raw_utterance missing from events; cols={cols}"
        assert "source_conv_id" in cols, f"source_conv_id missing from events; cols={cols}"

    def test_events_create_persists_raw_utterance(self, events_db) -> None:
        from lifeos.events import entries

        utterance = "aniversario de bodas el 15 de junio"
        ev = entries.create(
            kind="anniversary",
            title="Aniversario",
            when=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
            raw_utterance=utterance,
            source_conv_id=None,
        )
        # Read back from DB
        with events_db.connect() as conn:
            row = conn.execute(
                "SELECT raw_utterance, source_conv_id FROM events WHERE id = ?",
                (ev.id,),
            ).fetchone()
        assert row is not None
        assert row[0] == utterance, f"raw_utterance mismatch: {row[0]!r}"
        assert row[1] is None

    def test_events_create_without_raw_utterance_is_backward_compatible(self, events_db) -> None:
        """create() without raw_utterance must not error."""
        from lifeos.events import entries

        ev = entries.create(
            kind="milestone",
            title="Graduación",
            when=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert ev is not None
        assert ev.id

    def test_events_delete_soft_deletes(self, events_db) -> None:
        from lifeos.events import entries

        ev = entries.create(
            kind="party",
            title="Fiesta",
            when=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
        )
        result = entries.delete(ev.id)
        assert result is True
        # Should be gone from get()
        assert entries.get(ev.id) is None

    def test_events_verbatim_raw_utterance(self, events_db) -> None:
        """raw_utterance must store the VERBATIM original (un-normalized)."""
        from lifeos.events import entries

        # Simulate: number-word form that gets normalized for parsing
        original = "cumple María el catorce de febrero"  # verbatim original
        ev = entries.create(
            kind="birthday",
            title="Cumple María",
            when=datetime(2026, 2, 14, 12, 0, 0, tzinfo=timezone.utc),
            raw_utterance=original,
        )
        with events_db.connect() as conn:
            row = conn.execute(
                "SELECT raw_utterance FROM events WHERE id = ?",
                (ev.id,),
            ).fetchone()
        assert row[0] == original, (
            f"Verbatim original not preserved: {row[0]!r} != {original!r}"
        )


# ─────────────────────────────────────────────────────────────────
# "Also" — migration upgrade-path tests
# ─────────────────────────────────────────────────────────────────

class TestLearningMigrationUpgrade:
    """learning: existing rows get NULL for raw_capture columns on upgrade."""

    def test_existing_rows_get_null_after_migration(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
        monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learning_upg.db"))
        monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learning_upg.key"))

        from lifeos.learning import store

        # Apply only 001 + 002 (schema_version + entries table)
        with store.connect() as conn:
            store.MIGRATIONS[0](conn)
            store.MIGRATIONS[1](conn)
            conn.execute("INSERT INTO schema_version(version) VALUES (1)")
            conn.execute("INSERT INTO schema_version(version) VALUES (2)")
            conn.execute(
                "INSERT INTO learning_entries(id, ts, kind, title, source, confidence) "
                "VALUES ('old-le', '2026-01-01T00:00:00Z', 'idea', 'old idea', 'manual', 1.0)"
            )

        store.apply_migrations()

        with store.connect() as conn:
            row = conn.execute(
                "SELECT raw_utterance, source_conv_id FROM learning_entries WHERE id = 'old-le'"
            ).fetchone()
        assert row is not None
        assert row[0] is None, "raw_utterance should be NULL for pre-existing rows"
        assert row[1] is None, "source_conv_id should be NULL for pre-existing rows"


class TestSpiritualityMigrationUpgrade:
    """spirituality: existing rows get NULL for raw_capture columns on upgrade."""

    def test_existing_rows_get_null_after_migration(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
        monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit_upg.db"))
        monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit_upg.key"))

        from lifeos.spirituality import store

        with store.connect() as conn:
            store.MIGRATIONS[0](conn)
            store.MIGRATIONS[1](conn)
            conn.execute("INSERT INTO schema_version(version) VALUES (1)")
            conn.execute("INSERT INTO schema_version(version) VALUES (2)")
            conn.execute(
                "INSERT INTO spirituality_entries(id, ts, kind, title, source, confidence) "
                "VALUES ('old-se', '2026-01-01T00:00:00Z', 'gratitude', 'gracias', 'manual', 1.0)"
            )

        store.apply_migrations()

        with store.connect() as conn:
            row = conn.execute(
                "SELECT raw_utterance, source_conv_id FROM spirituality_entries WHERE id = 'old-se'"
            ).fetchone()
        assert row is not None
        assert row[0] is None
        assert row[1] is None


class TestRelationshipsMigration003To004:
    """relationships: existing rows get NULL for raw_capture columns on 003→004 upgrade."""

    def test_existing_interactions_get_null_after_migration(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
        monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel_upg.db"))
        monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel_upg.key"))

        from lifeos.relationships import store

        with store.connect() as conn:
            store.MIGRATIONS[0](conn)
            store.MIGRATIONS[1](conn)
            store.MIGRATIONS[2](conn)
            conn.execute("INSERT INTO schema_version(version) VALUES (1)")
            conn.execute("INSERT INTO schema_version(version) VALUES (2)")
            conn.execute("INSERT INTO schema_version(version) VALUES (3)")
            # Insert a person first (FK)
            conn.execute(
                "INSERT INTO people(id, name) VALUES ('p-old', 'OldPerson')"
            )
            conn.execute(
                "INSERT INTO interactions(id, ts, person_id, kind, title, source, confidence) "
                "VALUES ('i-old', '2026-01-01T00:00:00Z', 'p-old', 'conversation', 'old chat', 'manual', 1.0)"
            )

        store.apply_migrations()

        with store.connect() as conn:
            row = conn.execute(
                "SELECT raw_utterance, source_conv_id FROM interactions WHERE id = 'i-old'"
            ).fetchone()
        assert row is not None
        assert row[0] is None
        assert row[1] is None

    def test_migration_version_004_in_schema(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state2"))
        monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel_v4.db"))
        monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel_v4.key"))

        from lifeos.relationships import store
        store.apply_migrations()

        with store.connect() as conn:
            versions = {r[0] for r in conn.execute("SELECT version FROM schema_version").fetchall()}
        assert 4 in versions, f"Expected version 4 in schema_version, got: {versions}"


# ─────────────────────────────────────────────────────────────────
# Events undo — deleter must exist
# ─────────────────────────────────────────────────────────────────

class TestEventsDeletion:
    """events.delete() must soft-delete and return True."""

    def test_delete_returns_false_for_missing_id(self, events_db) -> None:
        from lifeos.events import entries
        result = entries.delete("nonexistent-id")
        assert result is False

    def test_delete_idempotent(self, events_db) -> None:
        from lifeos.events import entries

        ev = entries.create(
            kind="milestone",
            title="Test Milestone",
            when=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
        )
        assert entries.delete(ev.id) is True
        # Second delete: already deleted_at is set → rowcount 0 → False
        assert entries.delete(ev.id) is False
