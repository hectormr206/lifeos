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
from datetime import datetime, timedelta, timezone
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

# The reschedule job recomputes the adaptive daily hour at a FIXED time each
# day so its own cadence never drifts with the digest hour it manages. 04:00
# local sits safely inside quiet hours (the digest is clamped to 19:00-23:00),
# so recompute never collides with the digest firing.
_RESCHEDULE_HOUR = 4
_RESCHEDULE_MINUTE = 0


# Callable signature for the push dispatch — injected by the dashboard so
# this module stays free of axi imports.
PushFn = Callable[[str, str], None]   # (title, body) -> None

# Callable signature for the digest narrator — injected by the dashboard so
# this module stays free of axi imports. Takes the composed digest text
# (the FACTS) and returns a brain-narrated body.
NarratorFn = Callable[[str], str]     # (digest_text) -> narrated_body


_push_fn: PushFn | None = None
_narrator_fn: NarratorFn | None = None

# Adaptive-hour reschedule state — set by start_jobs, read by the daily
# reschedule job so it can recompute the digest hour without any DI (mirrors
# how _narrator_fn stores injected state at module scope). The current hour is
# tracked so the recompute is idempotent: it only re-registers the daily job
# when the freshly computed hour actually differs.
_adaptive_enabled: bool = False
_current_daily_hour: int = _DEFAULT_DAILY_HOUR
_current_daily_minute: int = _DEFAULT_DAILY_MINUTE


def set_push(fn: PushFn) -> None:
    """Inject the function used to dispatch insight notifications.

    The dashboard binds this to a closure over lifeos.push.send_to_all
    so we get the same delivery as reminders.
    """
    global _push_fn
    _push_fn = fn


def set_narrator(fn: NarratorFn | None) -> None:
    """Inject the function used to narrate the daily digest body.

    The dashboard binds this to a closure over axi.brain.ask (gated by the
    digest_narrate_enabled config key). Pass None to unbind — the daily
    push then uses the deterministic template body.
    """
    global _narrator_fn
    _narrator_fn = fn


def _dispatch(title: str, body: str) -> None:
    if _push_fn is None:
        log.info("insight composed (no push registered): %s", title)
        return
    try:
        _push_fn(title, body)
    except Exception:  # noqa: BLE001
        log.exception("insight push failed for %r", title)


def _narrate_or_template(template_body: str) -> tuple[str, bool]:
    """Return (push body, narrated?) for the daily digest.

    If a narrator is bound, its output becomes the body. On ANY exception
    or empty result, gracefully degrade to the deterministic template body
    (the job must never crash or go silent because the brain hiccuped).
    """
    if _narrator_fn is None:
        return template_body, False
    try:
        narrated = (_narrator_fn(template_body) or "").strip()
    except Exception:  # noqa: BLE001
        log.warning("digest narrator failed — falling back to template body",
                    exc_info=True)
        return template_body, False
    if not narrated:
        log.warning("digest narrator returned empty — falling back to template body")
        return template_body, False
    return narrated, True


def run_daily_now() -> str:
    """Compose + dispatch the daily digest. Returns the digest body for
    the dashboard's manual-trigger button."""
    d = digest.compose(cadence="daily")
    log.info("daily digest composed: sections=%d patterns=%d correlations=%d graph_facts=%d",
             d.sections_count, d.patterns_count, d.correlations_count,
             d.graph_facts_count)
    body, narrated = _narrate_or_template(d.body)
    title = "📊 Tu día, según Axi" if narrated else "📊 Resumen del día"
    _dispatch(title, body)
    return body


def run_weekly_now() -> str:
    d = digest.compose(cadence="weekly")
    log.info("weekly digest composed: sections=%d patterns=%d correlations=%d",
             d.sections_count, d.patterns_count, d.correlations_count)
    _dispatch("📊 Resumen semanal", d.body)
    return d.body


# Adaptive-hour window: a digest fired at 3am from weird sleep data would
# be wrong, so the computed hour is clamped (not rejected) to this range.
_ADAPTIVE_MIN_MINUTES = 19 * 60    # 19:00
_ADAPTIVE_MAX_MINUTES = 23 * 60    # 23:00
_ADAPTIVE_LEAD_MINUTES = 90        # digest fires 90 min before median bedtime
_ADAPTIVE_MIN_SAMPLES = 5
_ADAPTIVE_MAX_SAMPLES = 14


def adaptive_daily_hour(default_hour: int = _DEFAULT_DAILY_HOUR,
                        default_minute: int = _DEFAULT_DAILY_MINUTE) -> tuple[int, int]:
    """Compute the daily-digest hour from the user's median bedtime.

    Bedtime estimate = sleep entry ts (logged on waking) − sleep_hours.
    Uses the last 14 sleep vitals; fewer than 5 → the default. The result
    (median bedtime − 90 min) is clamped to [19:00, 23:00]. Any error →
    the default (defensive: scheduling must never crash startup).
    """
    try:
        from lifeos.health import entries as health_entries  # noqa: PLC0415

        tz = ZoneInfo(_LOCAL_TZ)
        bedtime_offsets: list[int] = []   # minutes since NOON, so bedtimes
        # around midnight sort contiguously instead of splitting at 00:00.
        for e in health_entries.list_recent(days=60, kind="vital", limit=300):
            data = e.data or {}
            if data.get("type") != "sleep_hours":
                continue
            try:
                hours = float(data.get("value"))
            except (TypeError, ValueError):
                continue
            if not 0.5 <= hours <= 16:
                continue
            ts = e.ts if e.ts.tzinfo else e.ts.replace(tzinfo=timezone.utc)
            bedtime = (ts - timedelta(hours=hours)).astimezone(tz)
            bedtime_offsets.append(
                (bedtime.hour * 60 + bedtime.minute - 12 * 60) % (24 * 60))
            if len(bedtime_offsets) >= _ADAPTIVE_MAX_SAMPLES:
                break

        if len(bedtime_offsets) < _ADAPTIVE_MIN_SAMPLES:
            return default_hour, default_minute

        bedtime_offsets.sort()
        n = len(bedtime_offsets)
        if n % 2:
            median = bedtime_offsets[n // 2]
        else:
            median = (bedtime_offsets[n // 2 - 1] + bedtime_offsets[n // 2]) // 2

        target = median - _ADAPTIVE_LEAD_MINUTES        # still noon-based
        target = max(_ADAPTIVE_MIN_MINUTES - 12 * 60,
                     min(target, _ADAPTIVE_MAX_MINUTES - 12 * 60))
        minutes_of_day = (target + 12 * 60) % (24 * 60)
        return divmod(minutes_of_day, 60)
    except Exception:  # noqa: BLE001
        log.warning("adaptive_daily_hour failed — using default %02d:%02d",
                    default_hour, default_minute, exc_info=True)
        return default_hour, default_minute


def resolve_daily_schedule(adaptive_enabled: bool) -> tuple[int, int, str]:
    """Return (hour, minute, source) for the daily digest job.

    source is 'adaptive from sleep median' or 'default' — for the startup
    log line. Recomputed on every dashboard start; the service restarts
    often enough that this acts as the weekly-ish refresh in practice.
    """
    if adaptive_enabled:
        hour, minute = adaptive_daily_hour()
        if (hour, minute) != (_DEFAULT_DAILY_HOUR, _DEFAULT_DAILY_MINUTE):
            return hour, minute, "adaptive from sleep median"
        return hour, minute, "default"
    return _DEFAULT_DAILY_HOUR, _DEFAULT_DAILY_MINUTE, "default"


def _daily_cron_trigger(hour: int, minute: int) -> CronTrigger:
    """Build the daily-digest CronTrigger in the local tz.

    Shared by initial registration and the reschedule job so both stay
    consistent on timezone handling.
    """
    return CronTrigger(hour=hour, minute=minute, timezone=ZoneInfo(_LOCAL_TZ))


def start_jobs(*, daily_hour: int = _DEFAULT_DAILY_HOUR,
               daily_minute: int = _DEFAULT_DAILY_MINUTE,
               weekly_weekday: int = _DEFAULT_WEEKLY_WEEKDAY,
               weekly_hour: int = _DEFAULT_WEEKLY_HOUR,
               weekly_minute: int = _DEFAULT_WEEKLY_MINUTE,
               adaptive_enabled: bool = False) -> dict[str, str]:
    """Register the insight jobs on the global scheduler.

    Idempotent — `replace_existing=True` means calling this multiple times
    (e.g. across dashboard restarts) updates the jobs in place.

    `adaptive_enabled` is stored so the daily reschedule job knows whether it
    may recompute the adaptive hour. When True, a lightweight job at
    _RESCHEDULE_HOUR:_RESCHEDULE_MINUTE local re-derives the digest hour from
    the sleep median each day, so the schedule tracks the user's drifting
    bedtime WITHOUT waiting for a dashboard restart.

    Returns the cron strings for the dashboard to display.
    """
    global _adaptive_enabled, _current_daily_hour, _current_daily_minute

    sched = get_scheduler()
    if not sched.running:
        log.warning("lifeos scheduler not running — skipping insight cron registration")
        return {}

    _adaptive_enabled = adaptive_enabled
    _current_daily_hour = daily_hour
    _current_daily_minute = daily_minute

    tz = ZoneInfo(_LOCAL_TZ)
    daily_trigger = _daily_cron_trigger(daily_hour, daily_minute)
    weekly_trigger = CronTrigger(
        day_of_week=weekly_weekday, hour=weekly_hour, minute=weekly_minute,
        timezone=tz,
    )
    reschedule_trigger = CronTrigger(
        hour=_RESCHEDULE_HOUR, minute=_RESCHEDULE_MINUTE, timezone=tz,
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
    # Daily adaptive-hour recompute. Registered unconditionally (idempotent via
    # replace_existing); it is a no-op at run time when adaptive is disabled.
    sched._scheduler.add_job(
        func=_safe_reschedule_daily, trigger=reschedule_trigger,
        id="lifeos.insights.reschedule", replace_existing=True,
        misfire_grace_time=3600,
    )
    # Register correlation_snapshot (hourly, defined in correlate.py).
    _register_correlation(sched)

    log.info(
        "insight jobs registered: daily=%02d:%02d, weekly=day%d@%02d:%02d, "
        "reschedule=%02d:%02d (adaptive=%s)",
        daily_hour, daily_minute, weekly_weekday, weekly_hour, weekly_minute,
        _RESCHEDULE_HOUR, _RESCHEDULE_MINUTE, adaptive_enabled,
    )
    return {
        "daily": f"{daily_minute} {daily_hour} * * *",
        "weekly": f"{weekly_minute} {weekly_hour} * * {weekly_weekday}",
    }


def reschedule_daily(adaptive_enabled: bool | None = None) -> bool:
    """Recompute the adaptive daily hour and re-register the daily job if it
    changed. Returns True if the daily job was re-registered, else False.

    `adaptive_enabled` defaults to the flag captured by start_jobs; callers
    (e.g. the dashboard, Option B) may pass it explicitly. When adaptive is
    disabled this is a no-op — the fixed hour stays put.

    Idempotent: if the recomputed (hour, minute) equals the currently-scheduled
    value, the scheduler is left untouched (no churn).
    """
    global _current_daily_hour, _current_daily_minute

    enabled = _adaptive_enabled if adaptive_enabled is None else adaptive_enabled
    if not enabled:
        return False

    hour, minute, source = resolve_daily_schedule(enabled)
    if (hour, minute) == (_current_daily_hour, _current_daily_minute):
        return False  # no drift — don't churn the scheduler

    sched = get_scheduler()
    if not sched.running:
        log.warning("lifeos scheduler not running — skipping daily reschedule")
        return False

    old_hour, old_minute = _current_daily_hour, _current_daily_minute
    sched._scheduler.add_job(
        func=_safe_run_daily, trigger=_daily_cron_trigger(hour, minute),
        id="lifeos.insights.daily", replace_existing=True,
        misfire_grace_time=3600,
    )
    _current_daily_hour = hour
    _current_daily_minute = minute
    log.info(
        "daily digest rescheduled: %02d:%02d -> %02d:%02d (%s)",
        old_hour, old_minute, hour, minute, source,
    )
    return True


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


def _safe_reschedule_daily() -> None:
    """apscheduler entry point for the daily adaptive-hour recompute. Must
    never throw out of the job — a bad recompute keeps the existing schedule."""
    try:
        reschedule_daily()
    except Exception:  # noqa: BLE001
        log.exception("daily digest reschedule crashed — keeping current schedule")
