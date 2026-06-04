"""Wire the insights pipeline to apscheduler.

Registers two recurring jobs:
  - daily insight  (default: every day at 21:00 local)
  - weekly insight (default: every Sunday at 20:00 local)

When the job fires, it composes the digest and dispatches it via Web
Push + OS notification (same channels as reminders). The body of the
notification is the digest text.

`start_jobs()` should be called from the dashboard startup hook AFTER
lifeos.scheduler.get_scheduler().start() has been called.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Callable
from zoneinfo import ZoneInfo

from apscheduler.triggers.cron import CronTrigger

from lifeos.insights import digest
from lifeos.insights.correlate import register as _register_correlation
from lifeos.scheduler import get_scheduler

log = logging.getLogger("lifeos.insights.cron")

# Default cadence — local Mexico City time.
_DEFAULT_DAILY_HOUR = 21
_DEFAULT_DAILY_MINUTE = 0
_DEFAULT_WEEKLY_WEEKDAY = 0   # Sunday in apscheduler (sun=0, mon=1, ... in cron-style)
_DEFAULT_WEEKLY_HOUR = 20
_DEFAULT_WEEKLY_MINUTE = 0
_LOCAL_TZ = "America/Mexico_City"


# Callable signature for the push dispatch — injected by the dashboard so
# this module stays free of axi imports.
PushFn = Callable[[str, str], None]   # (title, body) -> None


_push_fn: PushFn | None = None


def set_push(fn: PushFn) -> None:
    """Inject the function used to dispatch insight notifications.

    The dashboard binds this to a closure over lifeos.push.send_to_all
    so we get the same delivery as reminders.
    """
    global _push_fn
    _push_fn = fn


def _dispatch(title: str, body: str) -> None:
    if _push_fn is None:
        log.info("insight composed (no push registered): %s", title)
        return
    try:
        _push_fn(title, body)
    except Exception:  # noqa: BLE001
        log.exception("insight push failed for %r", title)


def run_daily_now() -> str:
    """Compose + dispatch the daily digest. Returns the digest body for
    the dashboard's manual-trigger button."""
    d = digest.compose(cadence="daily")
    log.info("daily digest composed: sections=%d patterns=%d correlations=%d",
             d.sections_count, d.patterns_count, d.correlations_count)
    _dispatch("📊 Resumen del día", d.body)
    return d.body


def run_weekly_now() -> str:
    d = digest.compose(cadence="weekly")
    log.info("weekly digest composed: sections=%d patterns=%d correlations=%d",
             d.sections_count, d.patterns_count, d.correlations_count)
    _dispatch("📊 Resumen semanal", d.body)
    return d.body


def start_jobs(*, daily_hour: int = _DEFAULT_DAILY_HOUR,
               daily_minute: int = _DEFAULT_DAILY_MINUTE,
               weekly_weekday: int = _DEFAULT_WEEKLY_WEEKDAY,
               weekly_hour: int = _DEFAULT_WEEKLY_HOUR,
               weekly_minute: int = _DEFAULT_WEEKLY_MINUTE) -> dict[str, str]:
    """Register the two insight jobs on the global scheduler.

    Idempotent — `replace_existing=True` means calling this multiple times
    (e.g. across dashboard restarts) updates the jobs in place.

    Returns the cron strings for the dashboard to display.
    """
    sched = get_scheduler()
    if not sched.running:
        log.warning("lifeos scheduler not running — skipping insight cron registration")
        return {}

    tz = ZoneInfo(_LOCAL_TZ)
    daily_trigger = CronTrigger(
        hour=daily_hour, minute=daily_minute, timezone=tz,
    )
    weekly_trigger = CronTrigger(
        day_of_week=weekly_weekday, hour=weekly_hour, minute=weekly_minute,
        timezone=tz,
    )

    sched._scheduler.add_job(
        func=_safe_run_daily, trigger=daily_trigger,
        id="lifeos.insights.daily", replace_existing=True,
        misfire_grace_time=3600,  # if the laptop was asleep at 21:00, fire within the hour
    )
    sched._scheduler.add_job(
        func=_safe_run_weekly, trigger=weekly_trigger,
        id="lifeos.insights.weekly", replace_existing=True,
        misfire_grace_time=7200,
    )
    # Register correlation_snapshot (hourly, defined in correlate.py).
    _register_correlation(sched)

    log.info(
        "insight jobs registered: daily=%02d:%02d, weekly=day%d@%02d:%02d",
        daily_hour, daily_minute, weekly_weekday, weekly_hour, weekly_minute,
    )
    return {
        "daily": f"{daily_minute} {daily_hour} * * *",
        "weekly": f"{weekly_minute} {weekly_hour} * * {weekly_weekday}",
    }


def _safe_run_daily() -> None:
    try:
        run_daily_now()
    except Exception:  # noqa: BLE001
        log.exception("scheduled daily insight crashed")


def _safe_run_weekly() -> None:
    try:
        run_weekly_now()
    except Exception:  # noqa: BLE001
        log.exception("scheduled weekly insight crashed")
