"""Tests for lifeos.scheduler."""

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


def test_scheduled_reminder_fires_and_dispatcher_runs() -> None:
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    fired = Event()
    seen_message: list[str] = []

    def dispatcher(rem):
        seen_message.append(rem.message)
        fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(milliseconds=400),
            message="ping",
            channel="log",
        )
        sched.schedule(rem)

        assert fired.wait(timeout=3.0), "dispatcher never fired"
        assert seen_message == ["ping"]

        # DAO updated to 'fired' — poll because mark_fired runs after dispatcher
        for _ in range(20):
            after = reminders.get(rem.id)
            if after and after.status == "fired":
                break
            time.sleep(0.1)
        assert after is not None and after.status == "fired"
    finally:
        sched.shutdown(wait=True)


def test_dispatcher_exception_marks_reminder_failed() -> None:
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    fired = Event()

    def bad_dispatcher(rem):
        fired.set()
        raise RuntimeError("simulated push failure")

    sched = Scheduler(dispatcher=bad_dispatcher)
    sched.start()
    try:
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(milliseconds=400),
            message="x",
            channel="push",
        )
        sched.schedule(rem)
        assert fired.wait(timeout=3.0)
        # apscheduler runs in a thread; give it a moment to record state
        for _ in range(20):
            after = reminders.get(rem.id)
            if after and after.status == "failed":
                break
            time.sleep(0.1)
        after = reminders.get(rem.id)
        assert after is not None
        assert after.status == "failed"
        assert "simulated push failure" in (after.error or "")
    finally:
        sched.shutdown(wait=True)


def test_start_loads_existing_pending_reminders() -> None:
    """Pending reminders saved before scheduler start should still fire."""
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(milliseconds=400),
        message="pre-existing",
        channel="log",
    )

    fired = Event()

    def dispatcher(r):
        if r.id == rem.id:
            fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        assert fired.wait(timeout=3.0), "pre-existing reminder never fired"
    finally:
        sched.shutdown(wait=True)


def test_cancel_removes_job_and_dispatcher_does_not_fire() -> None:
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    fired = Event()

    def dispatcher(_rem):
        fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        # Use a 5-second lead time so cancel is guaranteed to happen long before
        # the job would fire — eliminates the race between schedule() and cancel().
        rem = reminders.create(
            when=datetime.now(timezone.utc) + timedelta(seconds=5),
            message="cancel-me",
        )
        sched.schedule(rem)
        reminders.cancel(rem.id)
        sched.cancel(rem.id)

        # Deterministic check: the job must no longer exist in the scheduler.
        assert sched._scheduler.get_job(rem.id) is None, "job still present after cancel"

        # Confirm the dispatcher never fires within a short observation window.
        assert not fired.wait(timeout=0.5), "cancelled reminder fired anyway"
    finally:
        sched.shutdown(wait=True)


def test_past_due_reminder_fires_immediately() -> None:
    """If the laptop was asleep, past-due reminders should still fire on start."""
    from lifeos import reminders
    from lifeos.scheduler import Scheduler

    rem = reminders.create(
        when=datetime.now(timezone.utc) - timedelta(seconds=10),
        message="late",
        channel="log",
    )

    fired = Event()

    def dispatcher(r):
        if r.id == rem.id:
            fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        assert fired.wait(timeout=3.0), "past-due reminder did not catch up"
    finally:
        sched.shutdown(wait=True)
