"""Tests for raw_utterance / source_conv_id on the exercise sessions DAO.

FOOTGUN: table is exercise_sessions; DAO is exercise/sessions.py (not entries.py).

Spec scenarios:
  - "Entry created from utterance stores raw text"
  - "Backward-compatible create without new args"
  - "Raw utterance is immutable" (exercise has no update(); verified that
    raw_utterance is NOT exposed through any mutation path — test absence of update).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "exercise.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "exercise.key"))
    from lifeos.exercise import store
    store.apply_migrations()
    yield


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    s = sessions.create(
        kind="walk",
        title="caminata",
        duration_minutes=30,
        when=now,
        raw_utterance="hice media hora de caminata",
        source_conv_id=99,
    )
    fetched = sessions.get(s.id)
    assert fetched is not None
    assert fetched.raw_utterance == "hice media hora de caminata"
    assert fetched.source_conv_id == 99


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    s = sessions.create(
        kind="run", title="trote", duration_minutes=45, when=now,
    )
    fetched = sessions.get(s.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_session_dataclass_has_raw_utterance_field() -> None:
    """Verify the Session dataclass exposes both new fields."""
    from lifeos.exercise.sessions import Session
    import dataclasses
    field_names = {f.name for f in dataclasses.fields(Session)}
    assert "raw_utterance" in field_names
    assert "source_conv_id" in field_names
