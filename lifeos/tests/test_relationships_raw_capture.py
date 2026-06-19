"""Tests for raw_utterance / source_conv_id on the relationships interactions DAO.

FOOTGUN: migration version is 004 (003 is already _migration_003_interactions).
Table is 'interactions'; DAO is relationships/interactions.py.

Spec scenarios:
  - "Entry created from utterance stores raw text"
  - "Backward-compatible create without new args"
  - "Raw utterance is immutable"
  - Migration version 004 specifically
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "relationships.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "relationships.key"))
    from lifeos.relationships import store
    store.apply_migrations()
    yield


def _make_person(name: str = "Test Person") -> str:
    """Helper: create a person and return their id."""
    from lifeos.relationships import people
    p = people.create(name=name)
    return p.id


def test_migration_version_004_applied(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Confirm schema_version has version 4 after full apply_migrations."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state2"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel2.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel2.key"))
    from lifeos.relationships import store
    store.apply_migrations()
    with store.connect() as conn:
        versions = {r[0] for r in conn.execute("SELECT version FROM schema_version").fetchall()}
    assert 4 in versions, f"Version 4 not in schema_version: {versions}"


def test_interactions_table_has_raw_capture_columns() -> None:
    """Confirm both new columns exist on the interactions table."""
    from lifeos.relationships import store
    with store.connect() as conn:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(interactions)").fetchall()}
    assert "raw_utterance" in cols
    assert "source_conv_id" in cols


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.relationships import interactions
    person_id = _make_person()
    now = datetime.now(timezone.utc)
    i = interactions.create(
        person_id=person_id,
        kind="conversation",
        title="hablé con María",
        when=now,
        raw_utterance="hablé con María sobre el trabajo",
        source_conv_id=33,
    )
    fetched = interactions.get(i.id)
    assert fetched is not None
    assert fetched.raw_utterance == "hablé con María sobre el trabajo"
    assert fetched.source_conv_id == 33


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.relationships import interactions
    person_id = _make_person("Ana")
    now = datetime.now(timezone.utc)
    i = interactions.create(
        person_id=person_id,
        kind="call",
        title="llamada rápida",
        when=now,
    )
    fetched = interactions.get(i.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_soft_delete_is_available_and_preserves_raw_utterance() -> None:
    """Verify relationships has soft delete() and raw_utterance survives it."""
    from lifeos.relationships import interactions, store
    person_id = _make_person("Pedro")
    now = datetime.now(timezone.utc)
    i = interactions.create(
        person_id=person_id,
        kind="quality_time",
        title="cena especial",
        when=now,
        raw_utterance="cené con Pedro en el restaurante favorito",
    )
    result = interactions.delete(i.id)
    assert result is True
    # Soft-deleted: not visible in normal get()
    assert interactions.get(i.id) is None
    # Row preserved with raw_utterance intact
    with store.connect() as conn:
        row = conn.execute(
            "SELECT raw_utterance, deleted_at FROM interactions WHERE id = ?",
            (i.id,),
        ).fetchone()
    assert row is not None
    assert row["raw_utterance"] == "cené con Pedro en el restaurante favorito"
    assert row["deleted_at"] is not None
