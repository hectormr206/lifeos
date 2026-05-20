"""Tests for the reflect-on-impulse loop."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    from lifeos import store as core_store
    from lifeos.finance import store as fin_store
    core_store.apply_migrations()
    fin_store.apply_migrations()
    yield


def test_schedule_creates_reminder_for_big_purchase() -> None:
    from lifeos import reminders
    from lifeos.finance import entries
    from lifeos.finance.reflect import schedule_reflection_for

    e = entries.create(
        kind="big_purchase", title="iPhone", amount=20000,
        when=datetime.now(timezone.utc),
    )
    rid = schedule_reflection_for(e)
    assert rid is not None

    rem = reminders.get(rid)
    assert rem is not None
    assert "iPhone" in rem.message
    assert "impulsiva o planeada" in rem.message.lower()


def test_schedule_idempotent() -> None:
    from lifeos.finance import entries
    from lifeos.finance.reflect import schedule_reflection_for

    e = entries.create(
        kind="big_purchase", title="x", amount=3000,
        when=datetime.now(timezone.utc),
    )
    rid1 = schedule_reflection_for(e)
    # Re-fetch — entry now has reminder_id linked
    e2 = entries.get(e.id)
    rid2 = schedule_reflection_for(e2)
    assert rid1 == rid2


def test_schedule_no_op_for_entry_without_reflect_at() -> None:
    from lifeos.finance import entries
    from lifeos.finance.reflect import schedule_reflection_for

    e = entries.create(
        kind="expense", title="café", amount=50,
        when=datetime.now(timezone.utc),
    )
    assert schedule_reflection_for(e) is None


def test_cancel_reflection_removes_reminder() -> None:
    from lifeos import reminders
    from lifeos.finance import entries
    from lifeos.finance.reflect import (
        cancel_reflection_for,
        schedule_reflection_for,
    )

    e = entries.create(
        kind="big_purchase", title="x", amount=3000,
        when=datetime.now(timezone.utc),
    )
    rid = schedule_reflection_for(e)
    e2 = entries.get(e.id)
    ok = cancel_reflection_for(e2)
    assert ok is True
    rem = reminders.get(rid)
    assert rem is not None
    assert rem.status == "cancelled"
