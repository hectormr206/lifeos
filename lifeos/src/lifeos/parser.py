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
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Optional

import dateparser

log = logging.getLogger("lifeos.parser")


# Punctuation/space stripped from the ends of a normalized schedule key.
_NORM_STRIP = " \t\n\r.,;:!?¡¿\"'`()[]{}-—–…"


def normalize_schedule_text(text: str) -> str:
    """Normalize a schedule phrasing into a stable cache key.

    Lowercases, strips accents (NFKD decompose + drop combining marks),
    collapses any whitespace run to a single space, and strips leading/trailing
    punctuation and spaces. So "Quiero que todos los días me mandes X" and
    "quiero  que todos los dias me mandes x." map to the same key.

    Pure function — stdlib only, no side effects.
    """
    if not text or not isinstance(text, str):
        return ""
    decomposed = unicodedata.normalize("NFKD", text)
    no_accents = "".join(c for c in decomposed if not unicodedata.combining(c))
    collapsed = re.sub(r"\s+", " ", no_accents.lower())
    return collapsed.strip(_NORM_STRIP)


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
#
# We accept THREE shapes so word order and conjugation don't matter:
#   1. Enclitic imperative at the START ("tráeme/mándame/búscame/… las noticias").
#   2. Natural framed phrasing anywhere: "(quiero|necesito|quisiera|me gustaría)
#      que … me <verbo>" or bare indicative "me mandás/me mandas/me envías …".
#   3. Polite infinitive: "podrías/podés mandarme/enviarme/traerme/…".
#
# A content signal (or an http(s) URL) is still required so casual phrasing
# ("dame un abrazo") never misfires into an agentic task.

# Shape 1 — enclitic imperative. Matched anywhere (word-boundary bounded) so a
# leading recurrence phrase ("diariamente tráeme …") doesn't hide the verb. The
# content/URL signal below guards against casual misfires.
_AGENTIC_ENCLITIC = re.compile(
    r"\b(?:tr[aá]eme|m[aá]ndame|b[uú]scame|cons[ií]gueme|conseguime|"
    r"res[uú]meme|prep[aá]rame|[aá]rmame|dame)\b",
    re.IGNORECASE,
)

# Shape 2 — "me <verbo>" in subjunctive or indicative, anywhere in the text.
_AGENTIC_NATURAL = re.compile(
    r"\bme\s+(?:"
    r"mand[aáeé]s?|env[ií][aeé]s?|envi[eé]s|traig[ao]s|tra[eé]s|"
    r"des|das|busqu[eé]s|busc[aá]s|consig[ao]s|conse?gu[ií]s|"
    r"resum[ao]s|resum[ií]s|prepar[aeé]s?|arm[aeé]s?"
    r")\b",
    re.IGNORECASE,
)

# Shape 3 — polite infinitive with enclitic "-me".
_AGENTIC_INFINITIVE = re.compile(
    r"\b(?:mandarme|enviarme|traerme|darme|buscarme|conseguirme|"
    r"resumirme|prepararme|armarme)\b",
    re.IGNORECASE,
)

# Leading scheduling/intent framing to strip from the action prompt. Removes
# "(quiero|necesito|…) que", an optional "podrías/podés", an optional "me",
# and the delivery verb itself — keeping the actual content (and any URL).
_AGENTIC_FRAMING = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:(?:quiero|necesito|quisiera|me\s+gustar[ií]a)\s+que\s+)?"
    r"(?:podr[ií]as|pod[eé]s)?\s*"
    r"(?:me\s+)?"
    r"(?:tr[aá]eme|m[aá]ndame|b[uú]scame|cons[ií]gueme|conseguime|"
    r"res[uú]meme|prep[aá]rame|[aá]rmame|dame|"
    r"mand[aáeé]s?|env[ií][aeé]s?|envi[eé]s|traig[ao]s|tra[eé]s|"
    r"des|das|busqu[eé]s|busc[aá]s|consig[ao]s|conse?gu[ií]s|"
    r"resum[ao]s|resum[ií]s|prepar[aeé]s?|arm[aeé]s?|"
    r"mandarme|enviarme|traerme|darme|buscarme|conseguirme|"
    r"resumirme|prepararme|armarme)"
    r"\s+(?:de\s+|que\s+)?",
    re.IGNORECASE,
)

# An http(s) URL counts as a content signal on its own.
_URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)

# Word-boundary-aware time-marker matcher. Substring search (str.find) misfires
# on markers embedded in words (e.g. "en " inside "resumen"); a leading \b
# avoids that while still catching "a las 7", "en 30 minutos", "mañana", …
_WHEN_MARKER_RE = re.compile(
    r"\b(?:" + "|".join(re.escape(m) for m in _WHEN_MARKERS) + ")",
    re.IGNORECASE,
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

# Explicit clock time ANYWHERE in the text (am/pm aware). "a las 9", "a las
# 9:30", "a las 9 am", "a las 9 de la mañana", or a bare "9am"/"9 pm". Used so a
# daily recurrence can pick up an hour even when it is NOT adjacent to the
# recurrence phrase (e.g. "todos los días me mandes X a las 9 am").
_HOUR_AT = re.compile(
    r"\ba\s+las\s+(\d{1,2})(?::(\d{2}))?\s*"
    r"(a\.?\s?m\.?|p\.?\s?m\.?|de\s+la\s+(?:ma(?:ñ|n)ana|tarde|noche))?",
    re.IGNORECASE,
)
_HOUR_BARE = re.compile(
    r"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)\b", re.IGNORECASE
)


def _extract_hour(s: str) -> tuple[int, int] | None:
    """Find an explicit (hour, minute) anywhere in `s`, am/pm aware. None if absent."""
    m = _HOUR_AT.search(s) or _HOUR_BARE.search(s)
    if not m:
        return None
    h = int(m.group(1))
    mm = int(m.group(2) or 0)
    mod = (m.group(3) or "").replace(".", "").replace(" ", "").lower()
    if mod:
        pm = mod.startswith("pm") or "tarde" in mod or "noche" in mod
        am = mod.startswith("am") or "mañana" in mod or "manana" in mod
        if pm and h < 12:
            h += 12
        elif am and h == 12:
            h = 0
    if not (0 <= h <= 23 and 0 <= mm <= 59):
        return None
    return h, mm


def _detect_recurrence(text: str) -> tuple[str | None, str]:
    """If `text` describes a recurring pattern, return (cron_string, residual_text).

    Otherwise return (None, text). The residual is the text with the
    recurrence-phrase stripped so the time parser can keep going on what
    remains (e.g. "todos los días a las 9" → recurrence="0 9 * * *",
    residual="a las 9").
    """
    s = text.lower()

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

    # Daily/recurring. Covers "todos los días", "diariamente", "a diario",
    # "cada día"/"cada dia", "todas las mañanas". The hour is detected over the
    # WHOLE text (am/pm aware) — NOT required to be adjacent to the recurrence
    # phrase — so "todos los días me mandes X a las 9 am" → 09:00, and a daily
    # request with no hour at all defaults to 08:00 (morning briefing).
    daily_pat = (
        r"\b(?:todos\s+los\s+d[ií]as|diariamente|a\s+diario|"
        r"cada\s+d[ií]a|todas\s+las\s+ma(?:ñ|n)anas)\b"
    )
    if re.search(daily_pat, s):
        residual = re.sub(daily_pat, "", text, count=1, flags=re.IGNORECASE)
        hh = _extract_hour(s)
        h, mm = hh if hh else (8, 0)
        return f"{mm} {h} * * *", residual

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

    text = text.strip()

    # ── 1. Agentic intent: a delivery/fetch verb in any of the broadened
    #       shapes, AND a content signal (or a URL). Order-independent.
    has_verb = bool(
        _AGENTIC_ENCLITIC.search(text)
        or _AGENTIC_NATURAL.search(text)
        or _AGENTIC_INFINITIVE.search(text)
    )
    if not has_verb:
        return None
    if not (_AGENTIC_CONTENT.search(text) or _URL_RE.search(text)):
        return None

    # ── 2. Recurrence over the WHOLE text (word order doesn't matter). The
    #       residual has the recurrence phrase removed.
    recurrence, residual = _detect_recurrence(text)

    # An agentic "task" needs a schedule: either a recurrence or an explicit
    # time marker somewhere in the text. Otherwise it's just chatter.
    has_time_marker = _WHEN_MARKER_RE.search(text) is not None
    if not recurrence and not has_time_marker:
        return None

    # ── 3. Build the action prompt: drop the leading intent/scheduling framing
    #       and the delivery verb, then drop any trailing time expression. Keep
    #       the content and any URL.
    core = _AGENTIC_FRAMING.sub("", residual, count=1).strip(" ,;:.-")

    # Locate a trailing time expression in `core` (used both to clean the
    # prompt and, for one-shot tasks, to compute the first-run time).
    mt = _WHEN_MARKER_RE.search(core)
    cut_idx = mt.start() if mt else -1

    when_text = ""
    if cut_idx == 0:
        # The remainder is purely a time expression — no task content left.
        return None
    if cut_idx > 0:
        when_text = core[cut_idx:].strip(" ,;:.-")
        action_prompt = core[:cut_idx].strip(" ,;:.-")
    else:
        action_prompt = core
    if not action_prompt:
        return None

    # ── 4. Compute first-run time. Recurrence wins (next cron match); else use
    #       the parsed explicit time.
    when_utc: datetime | None = None
    if when_text and not recurrence:
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
            return None
        when_utc = parsed.astimezone(timezone.utc)
        if when_utc <= datetime.now(timezone.utc):
            from datetime import timedelta
            when_utc = when_utc + timedelta(days=1)
    elif recurrence:
        when_utc = _next_cron_match(recurrence, tz)

    if when_utc is None:
        return None

    return ReminderIntent(
        message=action_prompt, when=when_utc, recurrence=recurrence,
        action_kind="agentic", action_prompt=action_prompt,
    )


# Recurrence words that signal a repeating schedule. "cada" is included on its
# own (broad) per the gate's purpose: it only decides whether the LLM fallback
# is worth trying AFTER the regex parsers have already failed.
_RECURRENCE_WORDS = re.compile(
    r"\b(?:todos\s+los\s+d[ií]as|diariamente|a\s+diario|cada\s+d[ií]a|"
    r"cada\s+semana|semanal(?:mente)?|todas\s+las\s+ma(?:ñ|n)anas|cada)\b",
    re.IGNORECASE,
)

# A bare clock time ("8:30") or an am/pm time ("7 am", "7pm"). Complements
# _WHEN_MARKER_RE / _HOUR_AT which already cover "a las …" and "mañana/hoy".
_CLOCK_RE = re.compile(
    r"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*[ap]\.?\s?m\.?\b", re.IGNORECASE
)


def looks_schedulish(text: str) -> bool:
    """Cheap regex-only gate: does `text` carry ANY scheduling signal?

    Used to decide whether the (expensive) LLM schedule-parser fallback is worth
    invoking. Never calls an LLM. Returns True when the text contains a reminder
    trigger, an agentic delivery verb, a recurrence word, or a time marker
    (markers, "a las", "mañana", "hoy", a clock time, or am/pm); False otherwise.

    Deliberately permissive: an agentic verb ("tráeme las noticias") or a bare
    "cada" counts on its own, because the gate runs only AFTER the deterministic
    regex parsers have already declined, so a false positive costs at most one
    short, thinking-disabled brain call.
    """
    if not text or not isinstance(text, str):
        return False
    t = text.strip()
    if not t:
        return False
    if _REMINDER_TRIGGER.match(t):
        return True
    if (
        _AGENTIC_ENCLITIC.search(t)
        or _AGENTIC_NATURAL.search(t)
        or _AGENTIC_INFINITIVE.search(t)
    ):
        return True
    if _RECURRENCE_WORDS.search(t):
        return True
    if _WHEN_MARKER_RE.search(t):
        return True
    if _CLOCK_RE.search(t):
        return True
    return False


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
