"""Detect interaction phrases from chat text.

Recognized verbs:
    "hablé con X" / "platiqué con X" / "charlamos con X"  → conversation
    "pelea con X" / "discutimos" / "me peleé con X"        → conflict
    "llamé a X" / "me llamó X"                              → call
    "salí con X" / "fuimos con X" / "comí con X"            → quality_time
    "texteé a X" / "le escribí a X"                         → text

Person names are captured loosely: 1-3 capitalized words after the verb,
stopping at common Spanish connectors. The ingestion layer is intentionally
strict-precise: a missed match falls back to the brain or stays free-form.

A false match here would create a phantom Person row, which is worse than
missing a real interaction. So we err on the side of NOT matching when
in doubt.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.relationships.ingestion")


@dataclass(frozen=True, slots=True)
class InteractionIntent:
    kind: str          # conversation | conflict | quality_time | call | text
    person_name: str
    title: str
    body: str | None = None
    tags: list[str] = field(default_factory=list)
    confidence: float = 0.85


# Name capture: greedy across word chars + spaces. We let `_clean_name`
# validate that it actually looks like a proper name (uppercase-leading,
# 1-3 capitalized tokens, no stop-words eaten). Doing the case-sensitivity
# check in Python avoids fighting re.IGNORECASE, which would otherwise
# defeat the "must start with uppercase" intent of [A-Z] in the pattern.
_NAME = r"(?P<name>[\wÁÉÍÓÚÑáéíóúñü\s]+?)\s*(?:[.,;:!?]|$)"

# Tokens that may follow a person name and signal end-of-name (not part of it).
_STOP_AFTER_NAME = frozenset({
    "hoy", "ayer", "anoche", "mañana", "esta", "este", "esa", "ese",
    "porque", "para", "sobre", "de", "del", "en", "el", "la", "los",
    "las", "al", "a", "y", "pero", "que", "antes", "después", "despues",
    "muy", "mucho", "muchos", "sin", "con", "por",
    # EN
    "today", "yesterday", "tonight", "tomorrow", "this", "that",
    "because", "about", "and", "but", "the", "at", "on", "in", "for",
    "with", "after", "before", "last", "again",
})

# EN kinship terms accepted as the interaction person in "my X" phrases
# ("argued with my brother"). Lowercase in text, stored title-cased.
# Kept small on purpose — precision over recall.
_EN_KINSHIP = frozenset({
    "mom", "dad", "mother", "father", "brother", "sister",
    "grandma", "grandpa", "wife", "husband", "son", "daughter",
    "boyfriend", "girlfriend",
})


def _is_proper_name_token(tok: str) -> bool:
    """A token counts as a name token if its first char is uppercase
    (Unicode-aware) and it has no internal digits/punct beyond accent
    marks. 'María' yes, 'maría' no, 'X-23' no."""
    if not tok:
        return False
    if not tok[0].isupper():
        return False
    return tok.replace("-", "").replace("'", "").isalpha()


def _clean_name(raw: str) -> str | None:
    """Trim the captured name to its proper-name prefix. Returns None if
    the leading token isn't a proper-looking name."""
    raw = (raw or "").strip(" ,.;:!?")
    if not raw:
        return None
    tokens = raw.split()
    # EN kinship: "my brother" → "Brother". Only the exact two-token
    # "my <kinship>" shape — anything else falls through to the strict
    # proper-name path.
    if (
        len(tokens) >= 2
        and tokens[0].lower() == "my"
        and tokens[1].lower().rstrip(".,;:!?") in _EN_KINSHIP
    ):
        return tokens[1].rstrip(".,;:!?").capitalize()
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


# ─── Conversation ─────────────────────────────────────────────────────

_CONVERSATION_RE = re.compile(
    rf"\b(?:(?:habl[éeè]|platiqu[éeè]|charl(?:é|amos|am[oóò]))\s+con|"
    rf"(?:talked|spoke|chatted)\s+(?:to|with))\s+{_NAME}",
    re.IGNORECASE,
)


def _try_conversation(text: str) -> InteractionIntent | None:
    m = _CONVERSATION_RE.search(text)
    if not m:
        return None
    name = _clean_name(m.group("name"))
    if not name:
        return None
    return InteractionIntent(
        kind="conversation", person_name=name,
        title=f"conversación con {name}",
    )


# ─── Conflict ─────────────────────────────────────────────────────────

_CONFLICT_RE = re.compile(
    rf"\b(?:(?:(?:me\s+)?pele[éeè]|discut[íi](?:mos)?|tuv[eo]\s+(?:una\s+)?(?:pelea|discusi[oó]n))\s+con|"
    rf"(?:argued|had\s+a\s+fight|fought|had\s+an\s+argument)\s+with)\s+{_NAME}",
    re.IGNORECASE,
)
# Looser: "pelea con X" without a verb prefix
_CONFLICT_NOUN_RE = re.compile(
    rf"^\s*(?:axi[,:\s]+)?pelea\s+con\s+{_NAME}",
    re.IGNORECASE,
)


def _try_conflict(text: str) -> InteractionIntent | None:
    m = _CONFLICT_RE.search(text) or _CONFLICT_NOUN_RE.search(text)
    if not m:
        return None
    name = _clean_name(m.group("name"))
    if not name:
        return None
    return InteractionIntent(
        kind="conflict", person_name=name,
        title=f"discusión con {name}",
    )


# ─── Call ─────────────────────────────────────────────────────────────

_CALL_RE = re.compile(
    rf"\b(?:(?:llam[éeè]|le\s+llam[éeè])\s+a|(?<!is\s)(?<!was\s)called)\s+{_NAME}",
    re.IGNORECASE,
)
_CALL_INCOMING_RE = re.compile(
    rf"\b(?:me\s+llam[óo]|got\s+a\s+call\s+from)\s+{_NAME}",
    re.IGNORECASE,
)


def _try_call(text: str) -> InteractionIntent | None:
    m = _CALL_RE.search(text) or _CALL_INCOMING_RE.search(text)
    if not m:
        return None
    name = _clean_name(m.group("name"))
    if not name:
        return None
    return InteractionIntent(
        kind="call", person_name=name,
        title=f"llamada con {name}",
    )


# ─── Quality time ─────────────────────────────────────────────────────

_QUALITY_RE = re.compile(
    rf"\b(?:(?:sal[íi](?:mos)?|fu[ií](?:mos)?|com[íi](?:mos)?|cen[éeè](?:mos)?)\s+con|"
    rf"had\s+(?:lunch|dinner|breakfast|coffee)\s+with|"
    rf"went\s+out\s+with|hung\s+out\s+with)\s+{_NAME}",
    re.IGNORECASE,
)


def _try_quality_time(text: str) -> InteractionIntent | None:
    m = _QUALITY_RE.search(text)
    if not m:
        return None
    name = _clean_name(m.group("name"))
    if not name:
        return None
    return InteractionIntent(
        kind="quality_time", person_name=name,
        title=f"tiempo con {name}",
    )


# ─── Text / message ───────────────────────────────────────────────────

_TEXT_RE = re.compile(
    rf"\b(?:(?:le\s+(?:escrib[íi]|text(?:[éeè]|eé))|text(?:[éeè]|eé))\s+a|"
    rf"texted|messaged)\s+{_NAME}",
    re.IGNORECASE,
)


def _try_text(text: str) -> InteractionIntent | None:
    m = _TEXT_RE.search(text)
    if not m:
        return None
    name = _clean_name(m.group("name"))
    if not name:
        return None
    return InteractionIntent(
        kind="text", person_name=name,
        title=f"mensajes con {name}",
    )


# Order: conflict > quality_time > call > text > conversation
# (conflict signal is more specific; conversation is most generic)
_PARSERS = (_try_conflict, _try_quality_time, _try_call, _try_text, _try_conversation)


def parse_interaction(text: str) -> InteractionIntent | None:
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("relationships parser %s crashed: %s", parser.__name__, e)
    return None
