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
from typing import Callable, Optional

import dateparser

log = logging.getLogger("lifeos.parser")


# Trigger verbs at the start of the message (with optional leading "axi, ").
# Captures the remainder in group 1.
#
# The trigger verbs all imply "do this at a future time". We accept many
# natural ways the user might phrase it:
#   - record(a|á)me / recuérdame / acord(a|á)me — classical "remind me"
#   - avísame / avisame                          — "let me know"
#   - dime / decime / decíme                     — "tell me"
#   - llámame / llamame                          — "call/ping me"
#   - mándame / mandame                          — "send me"
#   - alertame                                   — "alert me"
#
# Critical safety: every trigger ALSO requires a time marker (handled later
# in parse_reminder via _WHEN_MARKERS). So "dime hola" by itself does NOT
# match — only "dime hola en 20 segundos" does. This prevents misfires on
# casual conversation.
_REMINDER_TRIGGER = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:"
    # -me / reflexive forms ("recordame", "recuérdame", "acordate")
    r"record(?:a|á)me|recu[ée]rdame|acord(?:a|á)me|acu[ée]rda(?:te|me)|"
    # bare imperatives ("recuerda llamar mañana", "acuérdate de X")
    r"recuerd[aá]|recu[ée]rda|acuerd[aá]|acu[ée]rda|"
    # other reminder verbs
    r"av[ií]same|"
    r"dime|dec[ií]me|"
    r"ll[áa]mame|"
    r"m[áa]ndame|"
    r"alertame|"
    r"no\s+(?:te\s+)?olvides"   # "no olvides X mañana", "no te olvides de X..."
    r")\s+"
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
    # Relative-time idioms — dateparser can't handle these, but the brain
    # fallback can. Splitting here ensures the message portion is clean.
    "después de", "despues de",  # "después de comer", "después del almuerzo"
    "cuando ",                    # "cuando termine la reunión"
    "tras ",                      # "tras la cena"
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
    # "a las 9" → "a las 9:00". dateparser misparses bare hours
    # ("mañana a las 9" returns tomorrow at current time, not 9 AM).
    # Only apply when the hour is followed by end-of-string, whitespace,
    # or punctuation — never when there's already a ":NN" or "am/pm".
    (re.compile(r"\ba\s+las\s+(\d{1,2})(?!\s*[:apmAPM\d])\b", re.IGNORECASE),
     lambda m: f"a las {int(m.group(1)):02d}:00"),
    # "el sábado a las X" — dateparser handles "sábado X" better than "el sábado a las X".
    (re.compile(r"\bel\s+", re.IGNORECASE), ""),
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
    when: datetime           # tz-aware UTC (first run for recurring)
    recurrence: str | None = None  # cron string ("0 9 * * *") or None
    action_kind: str = "message"   # "message" | "agentic"
    action_prompt: str | None = None  # task to run on each fire (agentic)


# Agentic triggers — verbs that mean "go fetch/curate something for me", as
# opposed to replaying a static message. Distinct from _REMINDER_TRIGGER.
_AGENTIC_TRIGGER = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:tr[aá]eme|m[aá]ndame|b[uú]scame|cons[ií]gueme|"
    r"res[uú]meme|prep[aá]rame|[aá]rmame|dame)\s+"
    r"(.+)$",
    re.IGNORECASE | re.DOTALL,
)

# Content signal — required alongside an agentic trigger so casual phrasing
# ("dame un abrazo") never misfires into an agentic task.
_AGENTIC_CONTENT = re.compile(
    r"\b(?:noticias|titulares|res[uú]men(?:es)?|clima|pron[oó]stico|"
    r"novedades|reporte|briefing|actualizaci[oó]n|tendencias)\b",
    re.IGNORECASE,
)


# Spanish weekday name → cron weekday number (Monday=1, Sunday=0).
# We accept both forms because Whisper/users transcribe inconsistently.
_WEEKDAYS = {
    "lunes": 1, "martes": 2, "miércoles": 3, "miercoles": 3,
    "jueves": 4, "viernes": 5, "sábado": 6, "sabado": 6, "domingo": 0,
}


def _detect_recurrence(text: str) -> tuple[str | None, str]:
    """If `text` describes a recurring pattern, return (cron_string, residual_text).

    Otherwise return (None, text). The residual is the text with the
    recurrence-phrase stripped so the time parser can keep going on what
    remains (e.g. "todos los días a las 9" → recurrence="0 9 * * *",
    residual="a las 9").
    """
    s = text.lower()

    # "todos los días a las HH(:MM)"
    m = re.search(r"\btodos\s+los\s+d[ií]as\s+a\s+las\s+(\d{1,2})(?::(\d{2}))?\b", s)
    if m:
        h = int(m.group(1)); mm = int(m.group(2) or 0)
        residual = re.sub(r"\btodos\s+los\s+d[ií]as\s+", "", text, count=1, flags=re.IGNORECASE)
        return f"{mm} {h} * * *", residual

    # "cada [weekday] a las HH(:MM)"
    weekdays_alt = "|".join(_WEEKDAYS.keys())
    m = re.search(rf"\bcada\s+({weekdays_alt})\s+a\s+las\s+(\d{{1,2}})(?::(\d{{2}}))?\b", s)
    if m:
        wd = _WEEKDAYS[m.group(1)]
        h = int(m.group(2)); mm = int(m.group(3) or 0)
        residual = re.sub(rf"\bcada\s+({weekdays_alt})\s+", "", text, count=1, flags=re.IGNORECASE)
        return f"{mm} {h} * * {wd}", residual

    # "cada X horas" / "cada X minutos"
    m = re.search(r"\bcada\s+(\d{1,3})\s+horas?\b", s)
    if m:
        n = int(m.group(1))
        residual = re.sub(r"\bcada\s+\d{1,3}\s+horas?\b", "", text, count=1, flags=re.IGNORECASE)
        return f"0 */{n} * * *", residual
    m = re.search(r"\bcada\s+(\d{1,3})\s+minutos?\b", s)
    if m:
        n = int(m.group(1))
        residual = re.sub(r"\bcada\s+\d{1,3}\s+minutos?\b", "", text, count=1, flags=re.IGNORECASE)
        return f"*/{n} * * * *", residual

    # "cada hora" / "cada minuto"  (singular shorthand for "cada 1")
    if re.search(r"\bcada\s+hora\b", s):
        residual = re.sub(r"\bcada\s+hora\b", "", text, count=1, flags=re.IGNORECASE)
        return "0 * * * *", residual
    if re.search(r"\bcada\s+minuto\b", s):
        residual = re.sub(r"\bcada\s+minuto\b", "", text, count=1, flags=re.IGNORECASE)
        return "* * * * *", residual

    return None, text


def parse_reminder(
    text: str,
    *,
    tz: str = "America/Mexico_City",
    brain_fallback: Callable[[str, str], Optional[datetime]] | None = None,
) -> Optional[ReminderIntent]:
    """Try to parse `text` as a reminder request. Returns None if it doesn't fit.

    `tz` is the user's local timezone — used to interpret things like
    "mañana a las 9" against the right day boundary.

    `brain_fallback` is an optional callable invoked when dateparser cannot
    interpret the when-expression. Signature: ``(when_text: str, tz: str) ->
    datetime | None``. Must return a timezone-aware datetime or None. If it
    raises, the exception is caught and None is returned. Defaults to None —
    callers that don't supply it keep the original behaviour.
    """
    if not text or not isinstance(text, str):
        return None

    m = _REMINDER_TRIGGER.match(text.strip())
    if not m:
        return None

    rest = m.group(1).strip()
    if not rest:
        return None

    # Pull out a recurrence pattern first (if any). The residual is then
    # processed for message + optional first-run time.
    recurrence, rest = _detect_recurrence(rest)
    rest = rest.strip(" ,;:.-")
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

    if cut_idx == 0:
        # marker at position 0 = no message text
        return None

    if cut_idx < 0:
        # No explicit time. Acceptable only for recurring reminders — the
        # cron schedule decides when to fire and `when` becomes the next
        # cron match from now.
        # Exception: if a brain_fallback is provided, give it the whole `rest`
        # text — it may be able to parse an implicit time expression like
        # "después del almuerzo" even without a canonical marker. On success,
        # use `rest` as both the message and time source.
        if not recurrence:
            if brain_fallback is None:
                return None
            try:
                fallback_dt = brain_fallback(rest, tz)
            except Exception:  # noqa: BLE001
                log.info("brain_fallback raised for %r (no marker), giving up", rest, exc_info=True)
                return None
            if fallback_dt is None:
                return None
            if fallback_dt.tzinfo is None:
                log.info(
                    "brain_fallback returned a naive datetime for %r — discarding", rest,
                )
                return None
            when_utc = fallback_dt.astimezone(timezone.utc)
            if when_utc <= datetime.now(timezone.utc):
                from datetime import timedelta
                when_utc = when_utc + timedelta(days=1)
            return ReminderIntent(message=rest, when=when_utc, recurrence=None)
        message = rest
        when_utc = _next_cron_match(recurrence, tz)
        if when_utc is None:
            return None
        return ReminderIntent(message=message, when=when_utc, recurrence=recurrence)

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
        if brain_fallback is not None:
            try:
                fallback_dt = brain_fallback(when_text, tz)
            except Exception:  # noqa: BLE001
                log.info("brain_fallback raised for %r, giving up", when_text, exc_info=True)
                return None
            if fallback_dt is None:
                return None
            if fallback_dt.tzinfo is None:
                log.info(
                    "brain_fallback returned a naive datetime for %r — discarding",
                    when_text,
                )
                return None
            parsed = fallback_dt
        else:
            return None

    when_utc = parsed.astimezone(timezone.utc)
    if when_utc <= datetime.now(timezone.utc):
        log.info("reminder fell in the past, shifting +1 day: %s", when_utc)
        from datetime import timedelta
        when_utc = when_utc + timedelta(days=1)

    return ReminderIntent(message=message, when=when_utc, recurrence=recurrence)


def parse_agentic_reminder(
    text: str,
    *,
    tz: str = "America/Mexico_City",
) -> Optional[ReminderIntent]:
    """Parse `text` as an agentic recurring/one-shot task. Returns None if it
    doesn't fit.

    Recognizes agentic triggers (tráeme/búscame/mándame …) that the static
    reminder parser ignores. Requires a content signal (noticias/clima/…) so
    casual phrasing never misfires. The resulting intent carries
    ``action_kind='agentic'`` and ``action_prompt`` (the curated task text);
    recurrence and first-run time are extracted with the same machinery as
    static reminders.
    """
    if not text or not isinstance(text, str):
        return None

    m = _AGENTIC_TRIGGER.match(text.strip())
    if not m:
        return None
    rest = m.group(1).strip()
    if not rest or not _AGENTIC_CONTENT.search(rest):
        return None

    recurrence, rest = _detect_recurrence(rest)
    rest = rest.strip(" ,;:.-")
    if not rest:
        return None

    # Split off a trailing time expression (if any). Everything before the
    # earliest time marker is the task prompt; from the marker on is "when".
    lower = rest.lower()
    cut_idx = -1
    for marker in _WHEN_MARKERS:
        i = lower.find(marker)
        if i != -1 and (cut_idx == -1 or i < cut_idx):
            cut_idx = i

    if cut_idx == 0:
        # The whole remainder is a time expression — no task content.
        return None

    if cut_idx < 0:
        # No explicit time. Acceptable only for recurring tasks.
        if not recurrence:
            return None
        action_prompt = rest
        when_utc = _next_cron_match(recurrence, tz)
        if when_utc is None:
            return None
        return ReminderIntent(
            message=action_prompt, when=when_utc, recurrence=recurrence,
            action_kind="agentic", action_prompt=action_prompt,
        )

    action_prompt = rest[:cut_idx].strip(" ,;:.-")
    when_text = rest[cut_idx:].strip(" ,;:.-")
    if not action_prompt or not when_text:
        return None

    parsed = dateparser.parse(
        _normalize_when(when_text),
        languages=["es"],
        settings={
            "TIMEZONE": tz,
            "RETURN_AS_TIMEZONE_AWARE": True,
            "PREFER_DATES_FROM": "future",
        },
    )
    if parsed is None:
        if recurrence:
            when_utc = _next_cron_match(recurrence, tz)
            if when_utc is None:
                return None
        else:
            return None
    else:
        when_utc = parsed.astimezone(timezone.utc)
        if when_utc <= datetime.now(timezone.utc):
            from datetime import timedelta
            when_utc = when_utc + timedelta(days=1)

    return ReminderIntent(
        message=action_prompt, when=when_utc, recurrence=recurrence,
        action_kind="agentic", action_prompt=action_prompt,
    )


def _next_cron_match(cron: str, tz_name: str) -> datetime | None:
    """Compute the next firing time for a cron expression. Returns None on
    invalid cron strings."""
    try:
        from apscheduler.triggers.cron import CronTrigger
        from zoneinfo import ZoneInfo

        trigger = CronTrigger.from_crontab(cron, timezone=ZoneInfo(tz_name))
        nxt = trigger.get_next_fire_time(None, datetime.now(ZoneInfo(tz_name)))
        if nxt is None:
            return None
        return nxt.astimezone(timezone.utc)
    except Exception as e:  # noqa: BLE001
        log.warning("invalid cron %r: %s", cron, e)
        return None
