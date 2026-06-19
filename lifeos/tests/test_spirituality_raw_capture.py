"""Tests for raw_utterance / source_conv_id on the spirituality entries DAO.

Spec scenarios:
  - "Entry created from utterance stores raw text"
  - "Backward-compatible create without new args"
  - Raw utterance is immutable (spirituality has no update(); soft-delete
    confirmed present via existing delete()).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirituality.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirituality.key"))
    from lifeos.spirituality import store
    store.apply_migrations()
    yield


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="reflection",
        title="reflexión del día",
        when=now,
        raw_utterance="hoy me sentí muy presente durante la meditación",
        source_conv_id=22,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance == "hoy me sentí muy presente durante la meditación"
    assert fetched.source_conv_id == 22


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="gratitude", title="agradecido hoy", when=now)
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_soft_delete_preserved_after_raw_capture() -> None:
    """Confirm delete() is soft (sets deleted_at) and raw_utterance survives."""
    from lifeos.spirituality import entries, store
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="meditation",
        title="sesión",
        when=now,
        raw_utterance="medité 20 minutos",
    )
    result = entries.delete(e.id)
    assert result is True
    # Entry gone from normal queries
    assert entries.get(e.id) is None
    # But the row still exists in DB (soft delete)
    with store.connect() as conn:
        row = conn.execute(
            "SELECT raw_utterance, deleted_at FROM spirituality_entries WHERE id = ?",
            (e.id,),
        ).fetchone()
    assert row is not None
    assert row["raw_utterance"] == "medité 20 minutos"
    assert row["deleted_at"] is not None
