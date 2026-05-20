"""Detect and structure health-related phrases from free-form chat text.

Strict regex-first. The brain fallback (when a phrase looks medical but
we can't match) is a future enhancement — for v1 we accept only patterns
we can interpret with high confidence, and fall through to the brain on
anything ambiguous. Better to miss a few than to mis-categorize sensitive
health data.

Public:
    parse_health(text) → HealthIntent | None

A HealthIntent has:
    kind: 'symptom'|'medication'|'vital'|'condition'|'note'
    title: short string
    data: kind-specific dict
    confidence: float (0..1)

Caller is expected to set source='chat' when persisting.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.health.ingestion")


@dataclass(frozen=True, slots=True)
class HealthIntent:
    kind: str
    title: str
    data: dict[str, Any] = field(default_factory=dict)
    body: str | None = None
    confidence: float = 0.85   # default for regex matches
    tags: list[str] = field(default_factory=list)


def _strip_accents(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", s)
        if not unicodedata.combining(c)
    )


# ─── Symptom: "me duele X" ─────────────────────────────────────────────

_SYMPTOM_RE = re.compile(
    r"\b(?:me\s+duele|tengo\s+dolor\s+de|me\s+est[áa]\s+doliendo)\s+"
    r"(?:la\s+|el\s+|los\s+|las\s+)?"
    r"([a-záéíóúñü\s]+?)"
    r"(?:\s+(?:de|con|porque|desde)|[,.;]|$)",
    re.IGNORECASE,
)


def _try_symptom(text: str) -> HealthIntent | None:
    m = _SYMPTOM_RE.search(text)
    if not m:
        return None
    location = m.group(1).strip().rstrip(" ,.;")
    if not location or len(location) > 40:
        return None
    return HealthIntent(
        kind="symptom",
        title=f"dolor de {location}",
        data={"location": location},
    )


# ─── Vital: "glucosa N", "presión X/Y", "peso N", "dormí N horas" ──────

_GLUCOSE_RE = re.compile(
    # Allow short bridge words ("salió", "en ayunas", "está en") between
    # "glucosa" and the number — up to ~25 chars but no sentence breaks.
    r"\bglucos[ao]\b[^.\n,;:]{0,25}?\s(\d{2,3})(?:\s*mg/?d?l)?\b",
    re.IGNORECASE,
)
_BP_RE = re.compile(
    r"\b(?:presi[oó]n(?:\s+arterial)?|p\.?a\.?)\s*(?:de|:)?\s*"
    r"(\d{2,3})\s*/\s*(\d{2,3})\b",
    re.IGNORECASE,
)
_WEIGHT_RE = re.compile(
    r"\b(?:peso|peso\s+actual|me\s+pes[éo])\s*(?:de|:)?\s*(\d{2,3}(?:\.\d{1,2})?)\s*(kg|kilos?)?\b",
    re.IGNORECASE,
)
_SLEEP_RE = re.compile(
    r"\bdorm[íi]\s*(?:unas?\s+)?(\d{1,2}(?:\.\d{1,2})?)\s*(?:horas?|hrs?|h)\b",
    re.IGNORECASE,
)


def _try_vital(text: str) -> HealthIntent | None:
    m = _GLUCOSE_RE.search(text)
    if m:
        v = int(m.group(1))
        return HealthIntent(
            kind="vital",
            title=f"glucosa {v} mg/dL",
            data={"type": "glucose", "value": v, "unit": "mg/dL"},
        )
    m = _BP_RE.search(text)
    if m:
        sys, dia = int(m.group(1)), int(m.group(2))
        return HealthIntent(
            kind="vital",
            title=f"presión {sys}/{dia}",
            data={"type": "blood_pressure", "systolic": sys, "diastolic": dia,
                  "unit": "mmHg"},
        )
    m = _WEIGHT_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital",
            title=f"peso {v} kg",
            data={"type": "weight", "value": v, "unit": "kg"},
        )
    m = _SLEEP_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital",
            title=f"dormí {v}h",
            data={"type": "sleep_hours", "value": v, "unit": "h"},
        )
    return None


# ─── Medication: "tomé X", "me tomé X", "tomé Y de X" ──────────────────

_MED_RE = re.compile(
    r"\b(?:me\s+)?tom[éeè]\s+"
    r"(?:una\s+|un\s+|la\s+|el\s+|mi\s+)?"
    r"(?:dosis\s+de\s+|pastilla\s+de\s+)?"
    r"([a-záéíóúñü0-9\s\-]+?)"
    r"(?:\s+(?:de|para|porque|por|hace|antes|despu[ée]s|esta|hoy|ayer)|[,.;]|$)",
    re.IGNORECASE,
)
# Common Spanish verbs that LOOK like "tomé" but aren't medicine.
_TOMÉ_FALSE_POSITIVES = {
    "agua", "café", "cafe", "té", "te", "leche", "jugo", "vino",
    "cerveza", "refresco", "el sol", "una foto", "el bus", "el tren",
    "una decisión", "una decision", "tiempo", "nota",
}


def _try_medication(text: str) -> HealthIntent | None:
    m = _MED_RE.search(text)
    if not m:
        return None
    name = m.group(1).strip().rstrip(" ,.;")
    if not name or len(name) > 60:
        return None
    name_norm = _strip_accents(name).lower().strip()
    if name_norm in _TOMÉ_FALSE_POSITIVES:
        return None
    return HealthIntent(
        kind="medication",
        title=f"tomé {name}",
        data={"name": name},
        confidence=0.75,  # weaker — "tomé" is overloaded
    )


# ─── Orchestrator ──────────────────────────────────────────────────────

# Order matters: try high-confidence parsers first.
_PARSERS = (_try_vital, _try_symptom, _try_medication)


def parse_health(text: str) -> HealthIntent | None:
    """Try to extract a health entry from `text`. Returns None on no match.

    Caller falls back to the brain for everything that returns None. The
    rule is "high precision over high recall": false positives in a
    health log are worse than missed entries (which the user can add
    manually anyway).
    """
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("health parser %s crashed: %s", parser.__name__, e)
    return None
