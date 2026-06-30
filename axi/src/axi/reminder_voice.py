"""Voice reminder fastpath for the Axi daemon.

Converts transcribed speech into a scheduled reminder when the text looks like
a reminder request (e.g. "Axi, recordame llamar a mamá después de comer").

Usage inside daemon.py::

    from axi.reminder_voice import try_create_reminder

    rid = try_create_reminder(text)
    if rid is not None:
        return f"reminder:{rid}"
    # ... fall through to intent classifier / dictation
"""

from __future__ import annotations

import logging
from zoneinfo import ZoneInfo

from axi import config
from axi.output import notify
from axi.reminder_brain import parse_when_brain
from lifeos import reminders
from lifeos.parser import parse_reminder
from lifeos.scheduler import get_scheduler

log = logging.getLogger(__name__)


def _pretty_when(when_utc, tz_name: str) -> str:
    """Return a short human-readable local-time string like 'sáb 23 14:00'."""
    tz = ZoneInfo(tz_name)
    local = when_utc.astimezone(tz)
    return local.strftime("%a %d %H:%M")


def try_create_reminder(text: str) -> str | None:
    """Try to parse *text* as a reminder request and persist it.

    Returns the reminder ID string on success, or None if:
    - the text does not look like a reminder, or
    - any step of create/schedule fails (error is logged; caller falls through
      to the normal intent-classifier / dictation pipeline).
    """
    tz_name = str(config.get("timezone", "America/Mexico_City"))

    try:
        ri = parse_reminder(text, brain_fallback=parse_when_brain)
    except Exception:  # noqa: BLE001
        log.exception("parse_reminder raised unexpectedly — falling through")
        return None

    # LLM schedule fallback: the regex parser declined. If the text still looks
    # schedulish, ask the brain (thinking disabled). Non-schedulish speech never
    # pays this cost — it falls straight through to the intent classifier.
    if ri is None:
        try:
            from lifeos.parser import looks_schedulish
            from axi.reminder_brain import cached_or_brain_parse
            if looks_schedulish(text):
                ri = cached_or_brain_parse(text, tz_name)
        except Exception:  # noqa: BLE001
            log.exception("schedule brain fallback raised — falling through")
            ri = None

    if ri is None:
        return None

    try:
        rem = reminders.create(
            when=ri.when,
            message=ri.message,
            channel="push",
            recurrence=ri.recurrence,
            action_kind=ri.action_kind,
            action_prompt=ri.action_prompt,
        )
        get_scheduler().schedule(rem)

        pretty = _pretty_when(ri.when, tz_name)
        log.info("voice reminder created id=%s message=%r when=%s", rem.id, ri.message, ri.when)

        notify(
            "Axi",
            f"Recordatorio: {ri.message} — {pretty}",
            icon="appointment-new",
            timeout_ms=4000,
        )
        return rem.id

    except Exception:  # noqa: BLE001
        log.exception("reminder create/schedule failed — falling through to dictation")
        return None
