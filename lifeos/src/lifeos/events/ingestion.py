"""Detect events from chat text.

Conservative — only birthdays and anniversaries get auto-parsed because
they're the clearest fixed-shape patterns. Travels, parties, deadlines,
meetings — all use the /events form (too ambiguous to regex without
risking phantom entries).

Recognized patterns:
    "cumple papá el 8/jun"   / "cumple de María 14 de febrero"      → birthday
    "aniversario 14 de febrero" / "aniversario X/Y el DATE"          → anniversary

Date parsing uses dateparser (reused from P1). Both relative phrases
("en 3 días") and explicit dates ("14 de febrero", "12/jun", "2026-06-12")
work — though for events the explicit form is usually what the user
wants.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

import dateparser

log = logging.getLogger("lifeos.events.ingestion")


@dataclass(frozen=True, slots=True)
class EventIntent:
    kind: str
    title: str
    when: datetime              # tz-aware UTC
    people: list[str] = field(default_factory=list)
    body: str | None = None
    confidence: float = 0.85


# Name capture: 1-3 capitalized tokens. Validated in Python (Unicode-aware)
# to dodge re.IGNORECASE polluting [A-Z] (lesson from relationships P5.1).
_NAME_LOOSE = r"(?P<name>[\wÁÉÍÓÚÑáéíóúñü\s]+?)"

_STOP_AFTER_NAME = frozenset({
    "hoy", "ayer", "anoche", "mañana", "esta", "este", "esa", "ese",
    "porque", "para", "sobre", "de", "del", "en", "el", "la", "los",
    "las", "al", "a", "y", "pero", "que",
    # EN
    "on", "is", "the", "this", "next", "today", "tomorrow", "and",
    "of", "in", "at",
})

# EN kinship terms accepted as the celebrated person in possessive
# birthday phrases ("mom's birthday …"). Lowercase in text, stored
# title-cased. Kept small on purpose — precision over recall.
_EN_KINSHIP = frozenset({
    "mom", "dad", "mother", "father", "brother", "sister",
    "grandma", "grandpa", "wife", "husband", "son", "daughter",
})


# Capitalized month names must never be peeled off as person names
# ("anniversary February 14" → date, not a person called February).
_MONTH_WORDS = frozenset({
    "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
    "agosto", "septiembre", "octubre", "noviembre", "diciembre",
    "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december",
})


def _is_proper_name_token(tok: str) -> bool:
    if not tok:
        return False
    if not tok[0].isupper():
        return False
    return tok.replace("-", "").replace("'", "").isalpha()


def _clean_name(raw: str) -> str | None:
    raw = (raw or "").strip(" ,.;:!?")
    if not raw:
        return None
    tokens = raw.split()
    out: list[str] = []
    for t in tokens:
        tlow = t.lower().rstrip(".,;:!?")
        if tlow in _STOP_AFTER_NAME:
            break
        if not _is_proper_name_token(t):
            break
        out.append(t)
        if len(out) >= 3:
            break
    if not out:
        return None
    return " ".join(out)


def _parse_when(text: str, tz_name: str = "America/Mexico_City") -> datetime | None:
    """Parse a date phrase from text. PREFER_DATES_FROM=future so 'el 14
    de febrero' resolves to next Feb 14, not last Feb 14.

    Strips leading articles ("el", "la") because dateparser chokes on
    "el 20 de mayo" but handles "20 de mayo".
    """
    if not text or not text.strip():
        return None
    cleaned = text.strip()
    cleaned = re.sub(r"^(?:el|la|un|una|los|las|on|the)\s+", "", cleaned, flags=re.IGNORECASE)
    parsed = dateparser.parse(
        cleaned,
        languages=["es", "en"],
        settings={
            "TIMEZONE": tz_name,
            "RETURN_AS_TIMEZONE_AWARE": True,
            "PREFER_DATES_FROM": "future",
            # Keep DMY for ambiguous slash dates ("8/12" = Dec 8) now that
            # "en" is in the language list (English defaults to MDY).
            "DATE_ORDER": "DMY",
        },
    )
    if parsed is None:
        return None
    return parsed.astimezone(timezone.utc)


# ─── Birthday ─────────────────────────────────────────────────────────

_BIRTHDAY_RE = re.compile(
    rf"\b(?:cumple(?:años)?\s+(?:de\s+)?|birthday\s+of\s+){_NAME_LOOSE}\s+"
    rf"(?:el\s+|en\s+|is\s+on\s+|on\s+)?(?P<when>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)

# EN possessive shape: "mom's birthday on June 8" / "María's birthday June 8".
# The name comes BEFORE the trigger word, so it needs its own pattern.
_BIRTHDAY_POSS_EN_RE = re.compile(
    rf"\b(?:my\s+)?(?P<name>[\wÁÉÍÓÚÑáéíóúñü\s]+?)['’]s\s+birthday\s+"
    rf"(?:is\s+)?(?:on\s+)?(?P<when>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _birthday_name(raw: str) -> str | None:
    """Resolve the celebrated person: proper name, or a bare EN kinship
    term ("mom's birthday") optionally preceded by "my"."""
    toks = (raw or "").strip(" ,.;:!?").split()
    if toks and toks[-1].lower() in _EN_KINSHIP and all(
        t.lower() == "my" for t in toks[:-1]
    ):
        return toks[-1].capitalize()
    return _clean_name(raw)


def _try_birthday(text: str) -> EventIntent | None:
    m = _BIRTHDAY_RE.search(text) or _BIRTHDAY_POSS_EN_RE.search(text)
    if not m:
        return None
    name = _birthday_name(m.group("name"))
    if not name:
        return None
    when = _parse_when(m.group("when"))
    if when is None:
        return None
    return EventIntent(
        kind="birthday",
        title=f"Cumple {name}",
        when=when,
        people=[name],
    )


# ─── Anniversary ──────────────────────────────────────────────────────

_ANNIVERSARY_RE = re.compile(
    r"\b(?:aniversario|anniversary)\s+(?:de\s+|of\s+)?(?:on\s+)?(?P<rest>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _try_anniversary(text: str) -> EventIntent | None:
    m = _ANNIVERSARY_RE.search(text)
    if not m:
        return None
    rest = m.group("rest").strip()
    # If `rest` starts with proper-name tokens, peel them off — dateparser
    # can't handle "María 14 de febrero", needs just "14 de febrero".
    tokens = rest.split()
    name_parts: list[str] = []
    date_start_idx = 0
    for i, t in enumerate(tokens):
        if (
            _is_proper_name_token(t)
            and t.lower() not in _MONTH_WORDS
            and len(name_parts) < 3
        ):
            name_parts.append(t)
            date_start_idx = i + 1
        else:
            break
    date_text = " ".join(tokens[date_start_idx:]) if name_parts else rest
    when = _parse_when(date_text)
    if when is None:
        return None
    name = " ".join(name_parts) if name_parts else None
    title = f"Aniversario {name}" if name else "Aniversario"
    people = [name] if name else []
    return EventIntent(
        kind="anniversary", title=title, when=when, people=people,
    )


_PARSERS = (_try_birthday, _try_anniversary)


def parse_event(text: str) -> EventIntent | None:
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("events parser %s crashed: %s", parser.__name__, e)
    return None
