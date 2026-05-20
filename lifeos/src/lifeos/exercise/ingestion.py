"""Detect exercise phrases from chat text.

Recognized verbs:
    "caminé X minutos" / "salí a caminar X min"  → walk
    "corrí X minutos" / "corrí X km"              → run (km goes into data)
    "hice yoga X min" / "yoga X min"              → yoga
    "X min de cardio" / "hice cardio X min"       → cardio
    "X min en el gym" / "entrené X min"           → strength
    "jugué fútbol/tenis/padel X min"              → sports

Either duration (minutes) or distance (km) MUST be present. Without a
quantity we don't match — saying "fui al gym" without time is too vague.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.exercise.ingestion")


@dataclass(frozen=True, slots=True)
class ExerciseIntent:
    kind: str
    title: str
    duration_minutes: int = 0
    data: dict[str, Any] = field(default_factory=dict)
    location: str | None = None
    confidence: float = 0.85


_MIN = r"min(?:utos?)?|mins?"

# ─── Walk ────────────────────────────────────────────────────────────

_WALK_MIN_RE = re.compile(
    rf"\bcamin[éeè](?:\s+(?:al\s+sol|por\s+el\s+parque))?\s+(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)
_WALK_KM_RE = re.compile(
    r"\bcamin[éeè]\s+(\d{1,3}(?:[.,]\d{1,2})?)\s*km\b",
    re.IGNORECASE,
)


def _km_to_walk_minutes(km: float) -> int:
    """Estimate walking time: ~12 min/km (~5 km/h)."""
    return int(round(km * 12))


def _try_walk(text: str) -> ExerciseIntent | None:
    m = _WALK_MIN_RE.search(text)
    if m:
        mins = int(m.group(1))
        if 1 <= mins <= 24 * 60:
            return ExerciseIntent(
                kind="walk", title="caminata", duration_minutes=mins,
            )
    m = _WALK_KM_RE.search(text)
    if m:
        km = float(m.group(1).replace(",", "."))
        if 0.1 <= km <= 100:
            return ExerciseIntent(
                kind="walk", title=f"caminata {km:g} km",
                duration_minutes=_km_to_walk_minutes(km),
                data={"distance_km": km},
            )
    return None


# ─── Run ─────────────────────────────────────────────────────────────

_RUN_MIN_RE = re.compile(
    rf"\b(?:corr[íi]|sal[íi]\s+a\s+correr)\s+(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)
_RUN_KM_RE = re.compile(
    r"\b(?:corr[íi]|sal[íi]\s+a\s+correr)\s+(\d{1,3}(?:[.,]\d{1,2})?)\s*km\b",
    re.IGNORECASE,
)


def _km_to_run_minutes(km: float) -> int:
    """Estimate running time: ~6 min/km."""
    return int(round(km * 6))


def _try_run(text: str) -> ExerciseIntent | None:
    m = _RUN_MIN_RE.search(text)
    if m:
        mins = int(m.group(1))
        if 1 <= mins <= 24 * 60:
            return ExerciseIntent(kind="run", title="trote", duration_minutes=mins)
    m = _RUN_KM_RE.search(text)
    if m:
        km = float(m.group(1).replace(",", "."))
        if 0.1 <= km <= 100:
            return ExerciseIntent(
                kind="run", title=f"trote {km:g} km",
                duration_minutes=_km_to_run_minutes(km),
                data={"distance_km": km},
            )
    return None


# ─── Yoga ────────────────────────────────────────────────────────────

_YOGA_RE = re.compile(
    rf"\b(?:hice\s+)?(?:yoga|pilates|estiramient[oó]s?)\s+(?:de\s+|por\s+)?(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)


def _try_yoga(text: str) -> ExerciseIntent | None:
    m = _YOGA_RE.search(text)
    if not m:
        return None
    mins = int(m.group(1))
    if not (1 <= mins <= 24 * 60):
        return None
    label = re.search(r"(yoga|pilates|estiramient[oó]s?)", text, re.IGNORECASE)
    title = (label.group(1).lower() if label else "yoga")
    return ExerciseIntent(kind="yoga", title=title, duration_minutes=mins)


# ─── Cardio ──────────────────────────────────────────────────────────

_CARDIO_RE = re.compile(
    rf"\b(?:hice\s+)?(\d{{1,3}})\s*(?:{_MIN})\s+de\s+cardio\b",
    re.IGNORECASE,
)
_CARDIO_VERB_RE = re.compile(
    rf"\bcardio\s+(?:de\s+|por\s+)?(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)


def _try_cardio(text: str) -> ExerciseIntent | None:
    m = _CARDIO_RE.search(text) or _CARDIO_VERB_RE.search(text)
    if not m:
        return None
    mins = int(m.group(1))
    if not (1 <= mins <= 24 * 60):
        return None
    return ExerciseIntent(kind="cardio", title="cardio", duration_minutes=mins)


# ─── Strength / gym ──────────────────────────────────────────────────

_STRENGTH_RE = re.compile(
    rf"\b(?:entren[éeè]|hice\s+pesas|fui\s+al\s+gym)\s+(?:de\s+|por\s+)?(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)
_STRENGTH_KIND_RE = re.compile(
    rf"\b(?:gym|pesas|fuerza)\s+(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)


def _try_strength(text: str) -> ExerciseIntent | None:
    m = _STRENGTH_RE.search(text) or _STRENGTH_KIND_RE.search(text)
    if not m:
        return None
    mins = int(m.group(1))
    if not (1 <= mins <= 24 * 60):
        return None
    return ExerciseIntent(
        kind="strength", title="entrenamiento de fuerza",
        duration_minutes=mins, location="gym",
    )


# ─── Sports ──────────────────────────────────────────────────────────

_SPORT_TERMS = ("fútbol", "futbol", "tenis", "pádel", "padel", "básquet",
                "basquet", "vóley", "voley", "ping pong", "natación", "natacion")
_SPORTS_RE = re.compile(
    rf"\bjug[uú][éeè]\s+(?:al\s+)?(?P<sport>"
    rf"{'|'.join(re.escape(s) for s in _SPORT_TERMS)})\s+"
    rf"(\d{{1,3}})\s*(?:{_MIN})\b",
    re.IGNORECASE,
)


def _try_sports(text: str) -> ExerciseIntent | None:
    m = _SPORTS_RE.search(text)
    if not m:
        return None
    sport = m.group("sport").lower()
    mins = int(m.group(2))
    if not (1 <= mins <= 24 * 60):
        return None
    return ExerciseIntent(
        kind="sports", title=sport, duration_minutes=mins,
    )


# Order: most specific first. Walks/runs with km are unambiguous; strength
# beats "hice X min" generic match.
_PARSERS = (_try_run, _try_walk, _try_yoga, _try_cardio, _try_strength, _try_sports)


def parse_exercise(text: str) -> ExerciseIntent | None:
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("exercise parser %s crashed: %s", parser.__name__, e)
    return None
