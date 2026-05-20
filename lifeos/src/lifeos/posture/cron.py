"""Cron job for scheduled posture scans.

The job is registered ALWAYS at startup (so changing the toggle later
doesn't require a restart) but checks `is_enabled()` at fire time. This
keeps the scheduling deterministic and toggleable.

Three pluggable callables are INJECTED — keeps lifeos free of axi imports:
  capture_fn() -> str    : returns base64 PNG of the current camera frame,
                            or empty string if no frame is available.
  brain_ask    : the multimodal LLM caller (axi.brain.ask).
  push_fn(title, body)   : the notification dispatcher
                            (closure over lifeos.push.send_to_all).

A separate `is_enabled_fn` is injected so the toggle can be flipped via
the dashboard's config system without touching this module.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Callable
from zoneinfo import ZoneInfo

from apscheduler.triggers.cron import CronTrigger

from lifeos.posture import analyze as _analyze
from lifeos.posture import scans as _scans
from lifeos.scheduler import get_scheduler

log = logging.getLogger("lifeos.posture.cron")


CaptureFn = Callable[[], str]
BrainAsk = Callable[..., str]
PushFn = Callable[[str, str], None]
EnabledFn = Callable[[], bool]


# Module-level injected callables (set via configure() at dashboard startup).
_capture_fn: CaptureFn | None = None
_brain_ask: BrainAsk | None = None
_push_fn: PushFn | None = None
_is_enabled_fn: EnabledFn | None = None
_cooldown_minutes: int = 30
_confidence_threshold: float = 0.6
_language: str = "es-MX"


def configure(*, capture_fn: CaptureFn, brain_ask: BrainAsk,
              push_fn: PushFn, is_enabled_fn: EnabledFn,
              cooldown_minutes: int = 30,
              confidence_threshold: float = 0.6,
              language: str = "es-MX") -> None:
    global _capture_fn, _brain_ask, _push_fn, _is_enabled_fn
    global _cooldown_minutes, _confidence_threshold, _language
    _capture_fn = capture_fn
    _brain_ask = brain_ask
    _push_fn = push_fn
    _is_enabled_fn = is_enabled_fn
    _cooldown_minutes = int(cooldown_minutes)
    _confidence_threshold = float(confidence_threshold)
    _language = language


def run_scan_now(*, source: str = "manual") -> _scans.Scan:
    """Force a scan now. Always executes regardless of the enable toggle
    (so the user can manually test via the /posture page).

    Honors cooldown for nudge dispatch but ALWAYS records the scan.
    """
    if _capture_fn is None or _brain_ask is None:
        return _scans.create(
            when=datetime.now(timezone.utc), state="error",
            error="cron not configured", source=source,
        )

    try:
        image_b64 = _capture_fn() or ""
    except Exception as e:  # noqa: BLE001
        log.exception("capture failed")
        return _scans.create(
            when=datetime.now(timezone.utc), state="error",
            error=f"capture: {e}", source=source,
        )

    if not image_b64:
        return _scans.create(
            when=datetime.now(timezone.utc), state="error",
            error="no camera frame available", source=source,
        )

    result = _analyze.analyze_frame(
        image_b64=image_b64, brain_ask=_brain_ask, language=_language,
    )
    nudge_sent = False
    if (result.state in {"slouched", "forward_head", "leaning"}
            and result.confidence >= _confidence_threshold
            and _push_fn is not None
            and not _scans.in_cooldown(_cooldown_minutes)
            and result.suggestion):
        title = "🪑 Postura" if _language.lower().startswith("es") else "🪑 Posture"
        try:
            _push_fn(title, result.suggestion)
            nudge_sent = True
        except Exception:  # noqa: BLE001
            log.exception("posture nudge push failed")
    return _scans.create(
        when=datetime.now(timezone.utc),
        state=result.state, confidence=result.confidence,
        suggestion=result.suggestion or None,
        nudge_sent=nudge_sent,
        source=source,
        raw_response=result.raw_response,
        error=result.error,
    )


def _scheduled_tick() -> None:
    """Called by apscheduler every N minutes within the work window."""
    if _is_enabled_fn is None or not _is_enabled_fn():
        return
    try:
        run_scan_now(source="scheduled")
    except Exception:  # noqa: BLE001
        log.exception("scheduled posture scan crashed")


def start_jobs(*, cadence_minutes: int = 25,
                start_hour: int = 9, end_hour: int = 18,
                weekdays_only: bool = True) -> str:
    """Register the recurring posture scan job. Idempotent.

    Default: every 25 minutes between 09:00-18:00 Mexico City time,
    Monday through Friday. Returns the cron expression for display.
    """
    sched = get_scheduler()
    if not sched.running:
        log.warning("lifeos scheduler not running — skipping posture cron registration")
        return ""

    tz = ZoneInfo("America/Mexico_City")
    cadence_minutes = max(1, min(int(cadence_minutes), 240))
    minute_field = f"*/{cadence_minutes}"
    hour_field = f"{start_hour}-{end_hour - 1}" if end_hour > start_hour else str(start_hour)
    day_of_week = "mon-fri" if weekdays_only else "*"

    trigger = CronTrigger(
        minute=minute_field, hour=hour_field, day_of_week=day_of_week, timezone=tz,
    )
    sched._scheduler.add_job(
        func=_scheduled_tick, trigger=trigger,
        id="lifeos.posture.scan", replace_existing=True,
        misfire_grace_time=120,  # if the laptop was idle a moment, fire when it wakes
    )
    cron_str = f"{minute_field} {hour_field} * * {day_of_week}"
    log.info("posture scan cron registered: %s", cron_str)
    return cron_str
