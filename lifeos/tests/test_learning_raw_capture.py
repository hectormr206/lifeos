"""Tests for raw_utterance / source_conv_id on the learning entries DAO.

Spec scenarios:
  - "Entry created from utterance stores raw text"
  - "Backward-compatible create without new args"
  - "Raw utterance is immutable" (via mark_done / update_progress — neither
    should wipe raw_utterance; learning has no generic update() so we verify
    update_progress does not clear raw_utterance).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learning.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learning.key"))
    from lifeos.learning import store
    store.apply_migrations()
    yield


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="note",
        title="aprendizaje del día",
        when=now,
        raw_utterance="aprendí sobre tipos en Python hoy",
        source_conv_id=15,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance == "aprendí sobre tipos en Python hoy"
    assert fetched.source_conv_id == 15


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="book", title="Clean Code", when=now)
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_update_progress_does_not_overwrite_raw_utterance() -> None:
    """Scenario: Raw utterance is immutable — update_progress() must not touch it."""
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="book",
        title="DDD",
        when=now,
        raw_utterance="empecé a leer DDD",
    )
    entries.update_progress(e.id, progress="cap 3/12")
    refetched = entries.get(e.id)
    assert refetched is not None
    assert refetched.raw_utterance == "empecé a leer DDD"
    assert refetched.progress == "cap 3/12"
