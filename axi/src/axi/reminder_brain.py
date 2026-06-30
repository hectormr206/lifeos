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
from datetime import datetime
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
