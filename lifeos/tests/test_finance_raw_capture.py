"""Tests for raw_utterance / source_conv_id on the finance entries DAO.

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
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    from lifeos.finance import store
    store.apply_migrations()
    yield


def test_create_persists_raw_utterance_and_conv_id() -> None:
    """Scenario: Entry created from utterance stores raw text."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="expense",
        title="cafe",
        amount=50.0,
        when=now,
        raw_utterance="gasté cincuenta pesos en un café",
        source_conv_id=7,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance == "gasté cincuenta pesos en un café"
    assert fetched.source_conv_id == 7


def test_create_without_raw_utterance_stores_null() -> None:
    """Scenario: Backward-compatible create without new args."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="expense", title="compra", amount=100.0, when=now)
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.raw_utterance is None
    assert fetched.source_conv_id is None


def test_update_does_not_overwrite_raw_utterance() -> None:
    """Scenario: Raw utterance is immutable — update() must not touch it."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="expense",
        title="original",
        amount=200.0,
        when=now,
        raw_utterance="gasté doscientos pesos",
    )
    updated = entries.update(
        e.id,
        kind="expense",
        title="corrected",
        amount=200.0,
        when=now,
        body="corrected body",
    )
    assert updated is not None
    assert updated.raw_utterance == "gasté doscientos pesos"
    refetched = entries.get(e.id)
    assert refetched is not None
    assert refetched.raw_utterance == "gasté doscientos pesos"
