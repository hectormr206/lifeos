"""Tests for lifeos.reminders DAO (TDD)."""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    from lifeos import store

    store.apply_migrations()
    yield


def test_create_and_get_roundtrip() -> None:
    from lifeos import reminders

    when = datetime.now(timezone.utc) + timedelta(hours=2)
    rem = reminders.create(when=when, message="llamar dentista", channel="push")

    assert rem.id
    assert rem.message == "llamar dentista"
    assert rem.channel == "push"
    assert rem.status == "pending"

    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.id == rem.id
    assert fetched.message == "llamar dentista"


def test_list_pending_orders_by_when_ascending() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    r3 = reminders.create(when=now + timedelta(hours=3), message="C")
    r1 = reminders.create(when=now + timedelta(hours=1), message="A")
    r2 = reminders.create(when=now + timedelta(hours=2), message="B")

    pending = reminders.list_pending()
    assert [r.id for r in pending] == [r1.id, r2.id, r3.id]


def test_list_pending_excludes_fired_and_cancelled() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    keep = reminders.create(when=now + timedelta(hours=1), message="keep")
    fired = reminders.create(when=now + timedelta(hours=1), message="fired")
    cancelled = reminders.create(when=now + timedelta(hours=1), message="cancel")

    reminders.mark_fired(fired.id)
    reminders.cancel(cancelled.id)

    pending_ids = [r.id for r in reminders.list_pending()]
    assert keep.id in pending_ids
    assert fired.id not in pending_ids
    assert cancelled.id not in pending_ids


def test_mark_fired_sets_fired_at() -> None:
    from lifeos import reminders

    r = reminders.create(when=datetime.now(timezone.utc), message="x")
    reminders.mark_fired(r.id)

    fetched = reminders.get(r.id)
    assert fetched is not None
    assert fetched.status == "fired"
    assert fetched.fired_at is not None


def test_mark_failed_records_error() -> None:
    from lifeos import reminders

    r = reminders.create(when=datetime.now(timezone.utc), message="x")
    reminders.mark_failed(r.id, "push subscription gone")

    fetched = reminders.get(r.id)
    assert fetched is not None
    assert fetched.status == "failed"
    assert fetched.error == "push subscription gone"


def test_cancel_is_idempotent() -> None:
    from lifeos import reminders

    r = reminders.create(when=datetime.now(timezone.utc), message="x")
    assert reminders.cancel(r.id) is True
    assert reminders.cancel(r.id) is False  # already cancelled


def test_cancel_unknown_returns_false() -> None:
    from lifeos import reminders

    assert reminders.cancel("nonexistent-ulid") is False


def test_list_recent_includes_fired_within_window() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    r = reminders.create(when=now - timedelta(minutes=5), message="x")
    reminders.mark_fired(r.id)

    recent = reminders.list_recent(days=30)
    assert any(x.id == r.id for x in recent)


def test_when_must_be_tz_aware() -> None:
    from lifeos import reminders

    naive = datetime(2026, 6, 1, 9, 0, 0)
    with pytest.raises(ValueError, match="tz-aware"):
        reminders.create(when=naive, message="x")
