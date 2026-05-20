"""Free-form text parsers for LifeOS intents.

P1 ships one parser: reminders. The user types into the chat (or speaks via
the daemon) something like "recordame llamar al dentista mañana a las 9" and
we extract: action='schedule-reminder', when=datetime, message=str.

Approach (per PRD §9.1):
1. Regex match the trigger ("recordame X", "acordame de X", "recuérdame X").
2. Heuristic split the remainder into (message, when-text).
3. Feed the when-text to `dateparser` (Spanish locale).
4. If parsing fails, return None — caller can decide to fall back to the brain.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

import dateparser

log = logging.getLogger("lifeos.parser")


# Trigger verbs at the start of the message (with optional leading "axi, ").
# Captures the remainder in group 1.
_REMINDER_TRIGGER = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:record(?:a|á)me|recu[ée]rdame|acord(?:a|á)me)\s+"
    r"(?:de\s+|que\s+)?"
    r"(.+)$",
    re.IGNORECASE | re.DOTALL,
)


# Time-expression markers — once any of these tokens appears in the remainder,
# everything from there on is treated as the date/time, and the prefix is the
# message. Order matters slightly: longer, more specific markers first.
_WHEN_MARKERS = (
    "el próximo", "el proximo", "la próxima", "la proxima",
    "este sábado", "este sabado", "este domingo", "este lunes",
    "este martes", "este miércoles", "este miercoles",
    "este jueves", "este viernes",
    "el sábado", "el sabado", "el domingo", "el lunes",
    "el martes", "el miércoles", "el miercoles",
    "el jueves", "el viernes",
    "mañana", "manana",
    "pasado mañana", "pasado manana",
    "hoy",
    "en ",       # "en 30 minutos", "en 2 horas"
    "a las",     # "a las 9", "a las 14:30"
    "dentro de", # "dentro de 2 horas"
)


# Spanish time idioms that dateparser doesn't recognize out of the box.
# Applied as a pre-processor before dateparser. We rewrite locution into
# explicit hours so the parser succeeds.
_IDIOM_REWRITES: list[tuple[re.Pattern[str], str]] = [
    # "8 de la noche" → "8 pm", "10 de la noche" → "22:00", etc.
    # We use 12-hour conversion: "X de la noche" is X+12 for X in 6..11, else X.
    (re.compile(r"\b(\d{1,2})\s+de\s+la\s+noche\b", re.IGNORECASE),
     lambda m: f"{(int(m.group(1)) + 12) % 24:02d}:00" if int(m.group(1)) < 12 else f"{int(m.group(1)):02d}:00"),
    (re.compile(r"\b(\d{1,2})\s+de\s+la\s+tarde\b", re.IGNORECASE),
     lambda m: f"{(int(m.group(1)) + 12) % 24:02d}:00" if int(m.group(1)) < 12 else f"{int(m.group(1)):02d}:00"),
    (re.compile(r"\b(\d{1,2})\s+de\s+la\s+ma(?:ñ|n)ana\b", re.IGNORECASE),
     lambda m: f"{int(m.group(1)):02d}:00"),
    # "y media" / "y cuarto" / "cuarto para X"
    (re.compile(r"\b(\d{1,2})\s+y\s+media\b", re.IGNORECASE),
     lambda m: f"{int(m.group(1)):02d}:30"),
    (re.compile(r"\b(\d{1,2})\s+y\s+cuarto\b", re.IGNORECASE),
     lambda m: f"{int(m.group(1)):02d}:15"),
    # "el sábado a las X" — dateparser handles "sábado X" better than "el sábado a las X".
    (re.compile(r"\bel\s+", re.IGNORECASE), ""),
    # "a las " is often noise to dateparser. Stripping it can help.
    (re.compile(r"\ba\s+las\s+", re.IGNORECASE), ""),
]


def _normalize_when(text: str) -> str:
    """Rewrite Spanish time idioms into forms dateparser handles."""
    out = text
    for pat, repl in _IDIOM_REWRITES:
        if callable(repl):
            out = pat.sub(repl, out)
        else:
            out = pat.sub(repl, out)
    return out.strip()


@dataclass(frozen=True, slots=True)
class ReminderIntent:
    message: str
    when: datetime  # tz-aware UTC


def parse_reminder(text: str, *, tz: str = "America/Mexico_City") -> Optional[ReminderIntent]:
    """Try to parse `text` as a reminder request. Returns None if it doesn't fit.

    `tz` is the user's local timezone — used to interpret things like
    "mañana a las 9" against the right day boundary.
    """
    if not text or not isinstance(text, str):
        return None

    m = _REMINDER_TRIGGER.match(text.strip())
    if not m:
        return None

    rest = m.group(1).strip()
    if not rest:
        return None

    # Find the earliest occurrence of any time marker. The chunk BEFORE it
    # is the message; the chunk FROM it on is the when-expression.
    lower = rest.lower()
    cut_idx = -1
    for marker in _WHEN_MARKERS:
        i = lower.find(marker)
        if i != -1 and (cut_idx == -1 or i < cut_idx):
            cut_idx = i

    if cut_idx <= 0:
        # No marker found, or marker is at position 0 (no message).
        return None

    message = rest[:cut_idx].strip(" ,;:.-")
    when_text = rest[cut_idx:].strip(" ,;:.-")
    if not message or not when_text:
        return None

    when_text_norm = _normalize_when(when_text)
    parsed = dateparser.parse(
        when_text_norm,
        languages=["es"],
        settings={
            "TIMEZONE": tz,
            "RETURN_AS_TIMEZONE_AWARE": True,
            "PREFER_DATES_FROM": "future",
        },
    )
    if parsed is None:
        log.info("dateparser could not interpret %r", when_text)
        return None

    when_utc = parsed.astimezone(timezone.utc)
    if when_utc <= datetime.now(timezone.utc):
        # If dateparser landed in the past (e.g. "a las 9" when it's 10 AM),
        # bump to tomorrow same time. Matches user intent in 99% of cases.
        log.info("reminder fell in the past, shifting +1 day: %s", when_utc)
        from datetime import timedelta
        when_utc = when_utc + timedelta(days=1)

    return ReminderIntent(message=message, when=when_utc)
