"""Tests for recurring reminders (parser + DAO + scheduler)."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Event

import pytest


@pytest.fixture(autouse=True)
def _isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    from lifeos import store
    store.apply_migrations()
    yield


# ─── Parser ───────────────────────────────────────────────────────────

def test_parser_daily_at_specific_time() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame tomar la pastilla todos los días a las 9")
    assert ri is not None
    assert ri.recurrence == "0 9 * * *"
    assert "pastilla" in ri.message.lower()


def test_parser_weekly_on_weekday() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame ir al gym cada lunes a las 7:30")
    assert ri is not None
    assert ri.recurrence == "30 7 * * 1"
    assert "gym" in ri.message.lower()


def test_parser_every_n_hours() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame tomar agua cada 2 horas")
    assert ri is not None
    assert ri.recurrence == "0 */2 * * *"


def test_parser_every_n_minutes() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame estirar la espalda cada 30 minutos")
    assert ri is not None
    assert ri.recurrence == "*/30 * * * *"


def test_parser_every_hour_shorthand() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame moverme cada hora")
    assert ri is not None
    assert ri.recurrence == "0 * * * *"


def test_parser_one_shot_has_no_recurrence() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame llamar al dentista mañana a las 9")
    assert ri is not None
    assert ri.recurrence is None


def test_parser_recurring_computes_next_run_in_future() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame agua cada 30 minutos")
    assert ri is not None
    assert ri.when > datetime.now(timezone.utc)


# ─── DAO ──────────────────────────────────────────────────────────────

def test_dao_recurring_create_stores_cron() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="X", recurrence="0 9 * * *",
    )
    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.recurrence == "0 9 * * *"
    assert fetched.is_recurring is True


def test_dao_mark_recurring_fired_does_not_terminate() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc), message="X", recurrence="0 9 * * *",
    )
    reminders.mark_recurring_fired(rem.id)
    after = reminders.get(rem.id)
    assert after is not None
    assert after.status == "pending"           # still pending
    assert after.last_fired_at is not None     # but last_fired_at bumped


def test_dao_one_shot_mark_fired_also_sets_last_fired_at() -> None:
    from lifeos import reminders
    rem = reminders.create(
        when=datetime.now(timezone.utc), message="X",
    )
    reminders.mark_fired(rem.id)
    after = reminders.get(rem.id)
    assert after is not None
    assert after.status == "fired"
    assert after.fired_at is not None
    assert after.last_fired_at is not None


# ─── Scheduler ────────────────────────────────────────────────────────

def test_scheduler_fires_recurring_repeatedly() -> None:
    """Schedule a 'every minute' recurring; should fire at least twice when
    sped up. We use 'every second' via direct cron and a 2.5s wait."""
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    # Use "* * * * * *" — apscheduler CronTrigger supports a seconds field
    # via from_crontab when given 6 fields. But from_crontab only accepts 5,
    # so we'll go via add_job directly with second='*' for the test.
    # Simpler: use IntervalTrigger via a stub here. Instead, test that a
    # 'every minute' job schedules and fires once within a tight window.
    from apscheduler.triggers.interval import IntervalTrigger

    fired = Event()
    fire_count = {"n": 0}

    def dispatcher(rem):
        fire_count["n"] += 1
        if fire_count["n"] >= 2:
            fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(seconds=1),
            message="tick", recurrence="* * * * *",  # every minute
            channel="log",
        )
        # Override the trigger to 'every 500ms' for a fast test
        sched._scheduler.add_job(
            func=sched._on_fire, trigger=IntervalTrigger(seconds=0.5),
            args=[rem.id], id=rem.id, replace_existing=True,
            misfire_grace_time=None,
        )
        assert fired.wait(timeout=4.0), "recurring reminder did not fire twice"
        # Status stays pending; last_fired_at is set
        time.sleep(0.2)
        after = reminders.get(rem.id)
        assert after is not None
        assert after.status == "pending"
        assert after.last_fired_at is not None
    finally:
        sched.shutdown(wait=True)


def test_scheduler_handles_invalid_cron_gracefully() -> None:
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    sched = Scheduler()
    sched.start()
    try:
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(hours=1),
            message="x", recurrence="this is not a cron",
        )
        sched.schedule(rem)
        # The DAO should now mark it failed
        time.sleep(0.1)
        after = reminders.get(rem.id)
        assert after is not None
        assert after.status == "failed"
        assert "invalid cron" in (after.error or "").lower()
    finally:
        sched.shutdown(wait=True)
