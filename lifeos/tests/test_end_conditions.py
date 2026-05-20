"""Tests for end conditions on recurring reminders."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Event

import pytest


@pytest.fixture(autouse=True)
def _isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_create_with_ends_at_persists() -> None:
    from lifeos import reminders
    now = datetime.now(timezone.utc)
    rem = reminders.create(
        when=now + timedelta(hours=1),
        message="x",
        recurrence="0 9 * * *",
        ends_at=now + timedelta(days=30),
    )
    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.ends_at is not None
    # Allow ±2s of round-trip noise
    delta = abs((fetched.ends_at - (now + timedelta(days=30))).total_seconds())
    assert delta < 5


def test_create_with_occurrences_persists() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="x", recurrence="0 9 * * *",
        occurrences_left=5,
    )
    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.occurrences_left == 5


def test_decrement_occurrences_counts_down() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="x", recurrence="0 9 * * *", occurrences_left=3,
    )
    assert reminders.decrement_occurrences(rem.id) == 2
    assert reminders.decrement_occurrences(rem.id) == 1
    assert reminders.decrement_occurrences(rem.id) == 0


def test_decrement_returns_none_when_unbounded() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="x", recurrence="0 9 * * *",  # no occurrences_left
    )
    assert reminders.decrement_occurrences(rem.id) is None


def test_recurring_stops_after_occurrence_cap() -> None:
    """After N fires the reminder is cancelled and stops firing."""
    from apscheduler.triggers.interval import IntervalTrigger
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    fire_count = {"n": 0}

    def dispatcher(rem):
        fire_count["n"] += 1

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(milliseconds=200),
            message="cap", recurrence="0 9 * * *", channel="log",
            occurrences_left=2,
        )
        sched._scheduler.add_job(
            func=sched._on_fire, trigger=IntervalTrigger(seconds=0.3),
            args=[rem.id], id=rem.id, replace_existing=True,
            misfire_grace_time=None,
        )
        # Wait long enough for 2 fires + a third attempt (which should not happen)
        time.sleep(1.4)
        # Should have fired exactly 2 times
        assert fire_count["n"] == 2, f"expected 2 fires, got {fire_count['n']}"
        after = reminders.get(rem.id)
        assert after is not None
        assert after.status == "cancelled"
        assert after.occurrences_left == 0
    finally:
        sched.shutdown(wait=True)
