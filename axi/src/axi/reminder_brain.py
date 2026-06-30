"""Brain fallback for ambiguous reminder time expressions.

Provides `parse_when_brain`, a callable that matches the `brain_fallback`
parameter of `lifeos.parser.parse_reminder`. When dateparser cannot interpret
a vague Spanish/English time phrase ("después del almuerzo", "cuando termine
el gym"), this module asks the LLM to convert it to an ISO 8601 timestamp.

The function is intentionally defensive: any parsing error, timeout, or
invalid response returns None rather than propagating exceptions.
"""

from __future__ import annotations

import json
import logging
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional
from zoneinfo import ZoneInfo

log = logging.getLogger("axi.reminder_brain")

_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL)

_SYSTEM_PROMPT_TEMPLATE = (
    "You convert vague Spanish/English time expressions to ISO 8601 timestamps. "
    "The current time is {now_iso} ({tz}). "
    "Return ONLY a JSON object with key 'when_iso' — either an ISO 8601 timestamp "
    "with timezone, or null. No prose, no markdown.\n"
    "CRITICAL: only return a timestamp when the text genuinely expresses WHEN "
    "something should happen (a date, clock time, or relative time like 'in 2 "
    "hours', 'después del almuerzo', 'mañana'). If the text is a task "
    "description, an instruction, an opinion, or has NO real temporal meaning, "
    "return null — do NOT invent or default to a time. When in doubt, return "
    "null.\n"
    "Examples:\n"
    '  "después del almuerzo" -> {{"when_iso": "<today ~15:00 with tz>"}}\n'
    '  "mañana a las 9" -> {{"when_iso": "<tomorrow 09:00 with tz>"}}\n'
    '  "hacer las pruebas y borrarlas al final" -> {{"when_iso": null}}\n'
    '  "comprar pan" -> {{"when_iso": null}}'
)

_USER_PROMPT_TEMPLATE = "Convertí esta expresión a ISO 8601: {when_text}"


def parse_when_brain(when_text: str, tz: str) -> datetime | None:
    """Ask the LLM to parse a vague time expression into a timezone-aware datetime.

    Returns a tz-aware ``datetime`` on success, or ``None`` on any failure
    (timeout, invalid JSON, unparseable expression, etc.).

    This function is designed to be passed as ``brain_fallback`` to
    ``lifeos.parser.parse_reminder``.
    """
    try:
        from axi import brain as _brain

        local_tz = ZoneInfo(tz)
        now_local = datetime.now(local_tz)
        now_iso = now_local.isoformat(timespec="seconds")

        system = _SYSTEM_PROMPT_TEMPLATE.format(now_iso=now_iso, tz=tz)
        prompt = _USER_PROMPT_TEMPLATE.format(when_text=when_text)

        t0 = time.monotonic()
        raw = _brain.ask(
            prompt=prompt,
            system=system,
            max_tokens=64,
            timeout=5.0,
            think=False,
        )
        latency_ms = int((time.monotonic() - t0) * 1000)

        # Strip markdown fences if the model wrapped the response.
        m = _FENCE_RE.search(raw)
        if m:
            raw = m.group(1)
        raw = raw.strip()

        data = json.loads(raw)
        when_iso = data.get("when_iso")
        if when_iso is None:
            return None

        result = datetime.fromisoformat(str(when_iso))

        # Record metric opportunistically — never let this block the result.
        try:
            from lifeos import metrics as _metrics
            _metrics.record(
                stage="reminder_brain_fallback",
                latency_ms=latency_ms,
                text_length=len(when_text),
            )
        except Exception:  # noqa: BLE001
            pass

        return result

    except Exception:  # noqa: BLE001
        log.info("parse_when_brain failed for %r", when_text, exc_info=True)
        return None


# Full schedule parser fallback (reminder OR agentic task). Distinct from
# parse_when_brain (which only resolves a vague TIME phrase): this asks the LLM
# to classify the WHOLE message into a scheduling intent and returns a
# ReminderIntent ready for creation. Used only when the deterministic regex
# parsers decline AND lifeos.parser.looks_schedulish(text) is True.
_SCHEDULE_SYSTEM_TEMPLATE = (
    "You convert a user's Spanish/English message into a scheduling intent. "
    "The current time is {now_iso} ({tz}). "
    "Return ONLY a JSON object — no prose, no markdown — with EXACTLY these keys:\n"
    '{{"is_reminder": true|false, "kind": "agentic"|"message", '
    '"recurring": true|false, "cron": "<5-field cron>"|null, '
    '"when_iso": "<ISO8601 with timezone offset>"|null, '
    '"content": "<the task or reminder text>"}}\n'
    "Rules:\n"
    "- is_reminder=false if the text is NOT a request to schedule a reminder or "
    "recurring task (plain chat, a question, an opinion). When in doubt, false.\n"
    '- kind="agentic" when fulfilling it requires fetching or curating current '
    "information (news, weather, 'tráeme/búscame/mándame', or a URL is present). "
    'kind="message" for a plain personal reminder.\n'
    "- recurring=true with a 5-field cron (minute hour day-of-month month "
    "day-of-week) for a repeating schedule; otherwise recurring=false and put a "
    "single ISO8601 timestamp WITH timezone offset in when_iso.\n"
    "- CRON RULES: keep day-of-month and month as '*' UNLESS the user explicitly "
    "names a day number or month. For weekdays use the day-of-week field only "
    "(Mon=1..Sun=0; ranges '1-5', lists '1,4'). For an hour range like '9 a 18' "
    "use the hour field range ('9-18'). Never put weekdays into the day-of-month "
    "field.\n"
    "- content is the task to run (agentic) or the thing to be reminded "
    "(message), stripped of the scheduling words.\n"
    "Examples:\n"
    '  "tráeme las noticias todos los días a las 8" -> '
    '{{"is_reminder": true, "kind": "agentic", "recurring": true, '
    '"cron": "0 8 * * *", "when_iso": null, "content": "las noticias"}}\n'
    '  "cada lunes y jueves a las 8 tráeme un resumen" -> '
    '{{"is_reminder": true, "kind": "agentic", "recurring": true, '
    '"cron": "0 8 * * 1,4", "when_iso": null, "content": "un resumen"}}\n'
    '  "avísame cada hora de 9 a 18 que revise el correo" -> '
    '{{"is_reminder": true, "kind": "message", "recurring": true, '
    '"cron": "0 9-18 * * *", "when_iso": null, "content": "revisar el correo"}}\n'
    '  "recordame llamar al dentista mañana a las 9" -> '
    '{{"is_reminder": true, "kind": "message", "recurring": false, '
    '"cron": null, "when_iso": "<tomorrow 09:00 with offset>", '
    '"content": "llamar al dentista"}}\n'
    '  "hola cómo estás" -> '
    '{{"is_reminder": false, "kind": "message", "recurring": false, '
    '"cron": null, "when_iso": null, "content": ""}}'
)

_SCHEDULE_USER_TEMPLATE = "Convertí este mensaje a JSON: {text}"


def parse_reminder_brain(
    text: str,
    tz: str,
    *,
    ask: Optional[Callable[..., str]] = None,
):
    """Ask the LLM to parse `text` into a full scheduling intent.

    Returns a ``lifeos.parser.ReminderIntent`` on success, or ``None`` on ANY
    failure (timeout, invalid JSON, not-a-reminder, invalid cron, naive/missing
    datetime, missing fields). NEVER raises.

    `ask` is an injectable brain-call callable (default: ``axi.brain.ask``) so
    tests don't hit a real LLM. The model is invoked with thinking disabled
    (``think=False``) and a small token budget + short timeout.
    """
    if not text or not isinstance(text, str):
        return None

    try:
        from lifeos.parser import ReminderIntent, _next_cron_match

        _ask = ask
        if _ask is None:
            from axi import brain as _brain

            _ask = _brain.ask

        local_tz = ZoneInfo(tz)
        now_iso = datetime.now(local_tz).isoformat(timespec="seconds")
        system = _SCHEDULE_SYSTEM_TEMPLATE.format(now_iso=now_iso, tz=tz)
        prompt = _SCHEDULE_USER_TEMPLATE.format(text=text)

        raw = _ask(
            prompt=prompt,
            system=system,
            max_tokens=200,
            timeout=6.0,
            think=False,
        )

        m = _FENCE_RE.search(raw)
        if m:
            raw = m.group(1)
        data = json.loads(raw.strip())
    except Exception:  # noqa: BLE001
        log.info("parse_reminder_brain: brain/JSON step failed for %r", text, exc_info=True)
        return None

    try:
        if not isinstance(data, dict) or not data.get("is_reminder"):
            return None

        kind = data.get("kind")
        if kind not in ("agentic", "message"):
            kind = "message"

        content = (data.get("content") or "").strip()
        if not content:
            return None

        if bool(data.get("recurring")):
            cron = data.get("cron")
            if not isinstance(cron, str) or len(cron.split()) != 5:
                return None
            from apscheduler.triggers.cron import CronTrigger

            CronTrigger.from_crontab(cron)  # raises on invalid → caught below
            when = _next_cron_match(cron, tz)
            if when is None:
                return None
            recurrence: str | None = cron
        else:
            when_iso = data.get("when_iso")
            if not when_iso:
                return None
            parsed = datetime.fromisoformat(str(when_iso))
            if parsed.tzinfo is None:
                return None
            when = parsed.astimezone(timezone.utc)
            if when <= datetime.now(timezone.utc):
                # Mirror parse_reminder: a past one-shot is bumped to the future.
                when = when + timedelta(days=1)
            recurrence = None

        return ReminderIntent(
            message=content,
            when=when,
            recurrence=recurrence,
            action_kind=kind,
            action_prompt=content if kind == "agentic" else None,
        )
    except Exception:  # noqa: BLE001
        log.info("parse_reminder_brain: intent build failed for %r", text, exc_info=True)
        return None


def cached_or_brain_parse(
    text: str,
    tz: str,
    *,
    ask: Optional[Callable[..., str]] = None,
):
    """Resolve a schedule from the learned cache, else fall back to the 4B.

    Shared orchestrator for both call sites (chat + voice). It sits in FRONT of
    ``parse_reminder_brain``:

    1. Normalize the phrasing into a stable key.
    2. On a cache HIT for a recurring schedule, rebuild a ``ReminderIntent``
       from the cached (kind, recurrence, content) WITHOUT calling the 4B —
       ``when`` is the next cron match. If the cached cron can't be resolved
       (corrupt/uninvalidatable row), treat it as a miss and fall through.
    3. On a cache MISS, call ``parse_reminder_brain``, log the
       "regex-missed → 4B" event, and — for RECURRING results only — cache the
       (normalized phrasing → schedule) so the next near-identical phrasing is
       served instantly. One-shot (relative-time) intents are never cached.

    Cache/log are best-effort DATA only: any failure is swallowed and the 4B
    result still flows. NEVER raises.

    `ask` is forwarded to ``parse_reminder_brain`` so tests can inject a fake
    brain and assert it is called exactly once across repeated phrasings.
    """
    try:
        from lifeos import store
        from lifeos.parser import (
            ReminderIntent,
            _next_cron_match,
            normalize_schedule_text,
        )
    except Exception:  # noqa: BLE001
        # Cache layer unavailable — degrade gracefully to a plain brain call.
        return parse_reminder_brain(text, tz, ask=ask)

    norm = ""
    hit = None
    try:
        norm = normalize_schedule_text(text)
        if norm:
            hit = store.schedule_cache_get(norm)
    except Exception:  # noqa: BLE001
        log.info("cached_or_brain_parse: cache lookup failed for %r", text, exc_info=True)
        hit = None

    if hit:
        try:
            recurrence = hit.get("recurrence")
            kind = hit.get("kind") or "message"
            content = (hit.get("content") or "").strip()
            when = _next_cron_match(recurrence, tz) if recurrence else None
            if when is not None and content:
                return ReminderIntent(
                    message=content,
                    when=when,
                    recurrence=recurrence,
                    action_kind=kind,
                    action_prompt=content if kind == "agentic" else None,
                )
            # Corrupt/uninvalidatable row → fall through to the 4B.
        except Exception:  # noqa: BLE001
            log.info("cached_or_brain_parse: cache rebuild failed for %r", text, exc_info=True)

    # Cache MISS (or unusable hit): invoke the 4B.
    ri = parse_reminder_brain(text, tz, ask=ask)

    try:
        store.schedule_miss_log_add(
            raw_text=text,
            norm_text=norm,
            resolved=(ri is not None),
            kind=ri.action_kind if ri else None,
            recurrence=ri.recurrence if ri else None,
        )
    except Exception:  # noqa: BLE001
        log.info("cached_or_brain_parse: miss-log failed for %r", text, exc_info=True)

    try:
        # ONLY recurring parses are cached (stable cron). One-shots have a
        # relative time and MUST be re-parsed every time.
        if ri is not None and ri.recurrence:
            store.schedule_cache_put(
                norm,
                kind=ri.action_kind,
                recurrence=ri.recurrence,
                content=ri.action_prompt or ri.message,
            )
    except Exception:  # noqa: BLE001
        log.info("cached_or_brain_parse: cache put failed for %r", text, exc_info=True)

    return ri
