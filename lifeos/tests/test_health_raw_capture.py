"""Tests for raw_utterance / source_conv_id on the health entries DAO.

Spec scenarios:
  - "Entry created from utterance stores raw text"
  - "Backward-compatible create without new args"
  - "Raw utterance is immutable"
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos.health import store
    store.apply_migrations()
    yield


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="note",
        title="media hora de caminata",
        when=now,
        raw_utterance="hice media hora de ejercicio",
        source_conv_id=42,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance == "hice media hora de ejercicio"
    assert fetched.source_conv_id == 42


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="note", title="sin utterance", when=now)
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_update_does_not_overwrite_raw_utterance() -> None:
    """Scenario: Raw utterance is immutable — update() must not touch it."""
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="note",
        title="original",
        when=now,
        raw_utterance="original text",
    )
    updated = entries.update(
        e.id,
        kind="note",
        title="corrected",
        when=now,
        body="corrected body",
    )
    assert updated is not None
    # raw_utterance must remain unchanged
    assert updated.raw_utterance == "original text"
    # source_conv_id also must not be wiped
    refetched = entries.get(e.id)
    assert refetched is not None
    assert refetched.raw_utterance == "original text"
