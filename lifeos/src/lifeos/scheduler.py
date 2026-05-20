"""LifeOS scheduler — wraps apscheduler with our reminders model.

Design:

- One process-wide BackgroundScheduler instance (per dashboard process).
- On start(), we scan `reminders` for status='pending' and schedule each one.
- create_reminder() goes through the DAO AND schedules the job.
- cancel_reminder() updates DAO AND removes the apscheduler job if present.
- When a job fires, we run the registered dispatcher callback (default: log).
  Plugging in Web Push later is a one-line registration in the dashboard.

Why we DON'T use apscheduler's SQLAlchemyJobStore: our reminders table is
the source of truth; apscheduler's jobstore would duplicate state and require
a serializer for our callbacks. Reloading pending reminders on every boot is
trivial (one query) and avoids two stores of truth.
"""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone
from typing import Callable

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from lifeos import reminders, store

log = logging.getLogger("lifeos.scheduler")


Dispatcher = Callable[[reminders.Reminder], None]


def _default_dispatcher(rem: reminders.Reminder) -> None:
    """Channel='log' default — just logs. Replaced at runtime by push.send_to_all."""
    log.info("REMINDER FIRED [%s] %s", rem.id, rem.message)


class Scheduler:
    """Thin wrapper around BackgroundScheduler."""

    def __init__(self, dispatcher: Dispatcher | None = None) -> None:
        self._scheduler = BackgroundScheduler(timezone="UTC")
        self._dispatcher: Dispatcher = dispatcher or _default_dispatcher
        self._lock = threading.Lock()

    @property
    def running(self) -> bool:
        return self._scheduler.running

    def set_dispatcher(self, fn: Dispatcher) -> None:
        """Replace the dispatcher used when a job fires."""
        with self._lock:
            self._dispatcher = fn

    def start(self) -> None:
        """Apply migrations, load all pending reminders, start the loop.

        Safe to call once per process. Subsequent calls are no-ops.
        """
        with self._lock:
            if self._scheduler.running:
                return
            store.apply_migrations()
            for rem in reminders.list_pending():
                self._schedule_job(rem)
            self._scheduler.start()
            log.info("lifeos scheduler started")

    def shutdown(self, wait: bool = False) -> None:
        with self._lock:
            if self._scheduler.running:
                self._scheduler.shutdown(wait=wait)
                log.info("lifeos scheduler stopped")

    def schedule(self, rem: reminders.Reminder) -> None:
        """Schedule an already-persisted reminder."""
        with self._lock:
            self._schedule_job(rem)

    def cancel(self, rid: str) -> None:
        """Remove the job from the scheduler (does NOT touch the DAO)."""
        with self._lock:
            try:
                self._scheduler.remove_job(rid)
            except Exception:  # noqa: BLE001 — job may not exist; that's fine
                pass

    # Internal — assumes lock is held by caller.
    def _schedule_job(self, rem: reminders.Reminder) -> None:
        # Recurring reminders use a CronTrigger from their `recurrence` field
        # ("0 9 * * *" = daily 9am). One-shot use a DateTrigger.
        # Past-due one-shots fire immediately (laptop was asleep edge case).
        run_date = rem.when_ts
        if run_date.tzinfo is None:
            run_date = run_date.replace(tzinfo=timezone.utc)

        if rem.recurrence:
            try:
                trigger = CronTrigger.from_crontab(rem.recurrence, timezone="UTC")
            except Exception as e:  # noqa: BLE001
                log.error("invalid cron %r for reminder %s: %s",
                          rem.recurrence, rem.id, e)
                reminders.mark_failed(rem.id, f"invalid cron: {e}")
                return
            self._scheduler.add_job(
                func=self._on_fire,
                trigger=trigger,
                args=[rem.id],
                id=rem.id,
                replace_existing=True,
                misfire_grace_time=None,
            )
        else:
            self._scheduler.add_job(
                func=self._on_fire,
                trigger="date",
                run_date=run_date,
                args=[rem.id],
                id=rem.id,
                replace_existing=True,
                misfire_grace_time=None,
            )

    def _on_fire(self, rid: str) -> None:
        """apscheduler callback. Re-reads the reminder (state may have changed)."""
        rem = reminders.get(rid)
        if rem is None:
            log.warning("reminder %s vanished before firing", rid)
            return
        if rem.status != "pending":
            log.info("reminder %s is %s — skipping fire", rid, rem.status)
            return
        try:
            self._dispatcher(rem)
            if rem.is_recurring:
                # Recurring: stay pending, just bump last_fired_at
                reminders.mark_recurring_fired(rid)
            else:
                reminders.mark_fired(rid)
        except Exception as e:  # noqa: BLE001
            log.exception("dispatcher failed for reminder %s", rid)
            reminders.mark_failed(rid, str(e))


# Process-wide instance. The dashboard starts/stops it; tests create their own.
_singleton: Scheduler | None = None
_singleton_lock = threading.Lock()


def get_scheduler() -> Scheduler:
    """Lazy singleton accessor for the dashboard process."""
    global _singleton
    with _singleton_lock:
        if _singleton is None:
            _singleton = Scheduler()
        return _singleton
