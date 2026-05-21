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
# Two BP shapes:
#   (1) "presión 120/80" — explicit keyword
#   (2) "120/80" or "116, 84" with optional "y pulso N" appended — bare numbers
#       only triggers when the numbers fall in physiological ranges to avoid
#       false positives on accounting/dimensions/codes.
_BP_RE = re.compile(
    r"\b(?:presi[oó]n(?:\s+arterial)?|p\.?a\.?)\s*(?:de|:)?\s*"
    r"(\d{2,3})\s*/\s*(\d{2,3})\b",
    re.IGNORECASE,
)
_BP_PULSE_BARE_RE = re.compile(
    # "116, 84 y pulso 72"  /  "116/84 pulso 72"  /  "116, 84 pulso 72"
    # Both sides have to be plausible (sys >= 80; dia >= 40) to avoid
    # eating "150, 200" type non-medical numbers — checked in Python.
    r"^\s*(\d{2,3})\s*[,/]\s*(\d{2,3})"
    r"(?:\s+y\s+|\s*,?\s+|\s*[.;]\s+)?"
    r"(?:pulso|fc|frecuencia\s+card[íi]aca|hr)\s*[:=]?\s*(\d{2,3})\b",
    re.IGNORECASE,
)
_WEIGHT_RE = re.compile(
    # "peso 75", "peso de 70.5kg", "me pesé/pese 65", "weight 64" (EN alias).
    # `pes[éeo]` allows the past tense with or without accent (Héctor often
    # writes "me pese" without accent) plus the present "me peso".
    r"\b(?:peso(?:\s+actual)?|me\s+pes[éeo]|weight)\s*(?:de|:|=)?\s*"
    r"(\d{2,3}(?:\.\d{1,2})?)\s*(kg|kilos?)?\b",
    re.IGNORECASE,
)
_SLEEP_HOURS_RE = re.compile(
    r"\bdorm[íi]\s*(?:unas?\s+)?(\d{1,2}(?:\.\d{1,2})?)\s*(?:horas?|hrs?|h)\b",
    re.IGNORECASE,
)
# Spanish number words 1-12 for clock hours. "media" handled separately.
_SP_HOUR_WORDS = {
    "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
    "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
}
# "una" pulls double duty as the indefinite article ("una hora") and the
# number 1. We only accept it in the clock context here.

# Natural-language sleep: "me dormí (a/como a) las X (am|pm|de la noche/mañana)
# ... desperté/me levanté/acabo de despertar (ahorita | a las Y)".
# Captures the START hour as either a digit OR a Spanish number word
# (una|dos|...|doce). END hour captured similarly or 'ahorita' = now.
_HOUR_WORD_ALT = "|".join(_SP_HOUR_WORDS.keys())
_SLEEP_FROM_TO_RE = re.compile(
    r"\bme\s+dorm[íi]\s*"
    r"(?:como\s+)?"                                 # "como a la una"
    r"(?:a\s+)?"
    r"(?:la\s+|las\s+)?"
    rf"(\d{{1,2}}|{_HOUR_WORD_ALT})"                # group 1: start hour (digit OR word)
    r"(?::(\d{2}))?\s*"                             # group 2: optional minutes
    r"(?:de\s+la\s+(noche|ma[ñn]ana|tarde|madrugada)|am|pm|h)?"   # group 3: period
    r".{1,120}?"
    r"(?:desp[eé]rt[éo]|me\s+levant[éo]|acabo\s+de\s+(?:despertar|levantar))"
    r"(?:.{0,40}?"
    r"(?:(ahorita|ya|reci[eé]n)"                    # group 4: "now" marker
    r"|a\s+(?:la\s+|las\s+)?"
    rf"(\d{{1,2}}|{_HOUR_WORD_ALT})"                # group 5: end hour
    r"(?::(\d{2}))?))?",                            # group 6: end minutes
    re.IGNORECASE | re.DOTALL,
)


def _parse_hour_token(tok: str) -> int | None:
    """Parse '8' or 'ocho' → 8. Returns None on invalid."""
    if not tok:
        return None
    tok = tok.strip().lower()
    if tok.isdigit():
        n = int(tok)
        return n if 0 <= n <= 23 else None
    return _SP_HOUR_WORDS.get(tok)


# Single-field body fat / weight / muscle parsers — when only ONE field is
# in the message (so _try_body_composition's ≥2 threshold misses it).
_SINGLE_BODY_FAT_RE = re.compile(
    r"\b(?:grasa(?:\s+corporal)?|body\s*fat|fat|fac)\s*[:=]?\s*"
    r"(\d{1,2}(?:\.\d{1,2})?)\s*%?\b",
    re.IGNORECASE,
)
_SINGLE_MUSCLE_RE = re.compile(
    r"\b(?:m[uú]sculo|muscle|masa\s+muscular)\s*[:=]?\s*"
    r"(\d{1,2}(?:\.\d{1,2})?)\s*%?\b",
    re.IGNORECASE,
)
_SINGLE_BMI_RE = re.compile(
    r"\b(?:imc|bmi)\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\b",
    re.IGNORECASE,
)
_SINGLE_RM_RE = re.compile(
    r"\b(?:rm|bmr|metabolismo\s+basal|tasa\s+metab[oó]lica)\s*[:=]?\s*(\d{3,5})\b",
    re.IGNORECASE,
)
_SINGLE_VISCERAL_RE = re.compile(
    r"\bvisceral(?:\s+(?:fat|fac))?\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\b",
    re.IGNORECASE,
)


# ─── Body composition (Inbody / scale): peso, músculo, grasa, RM, IMC ─
#
# Cases the user actually writes:
#   "Musculo 34.5%, RM 1435, weight 64, FAC 18.7%, visceral FAC 8. BMI 25"
#   "Es FAT 18.7."
#   "grasa 19%, musculo 33"
#
# Each field is independently parsed from the same input. The result is
# ONE entry of kind="vital" with data.type="body_composition" + all the
# fields we found. We also handle FAC as an alias for FAT (typo: el user
# escribe FAC en vez de FAT consistentemente, así lo trata como sinónimo).
_BODY_FIELD_PATTERNS = [
    # (name in output, regex with one capture group for the numeric value,
    #  optional unit). Order matters: more specific patterns first so
    #  "visceral fat" is captured separately from plain "fat".
    ("visceral_fat",
     re.compile(r"\bvisceral(?:\s+(?:fat|fac))?\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\b", re.IGNORECASE),
     ""),
    ("body_fat_pct",
     re.compile(r"\b(?:grasa(?:\s+corporal)?|fat|fac)\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\s*%?\b", re.IGNORECASE),
     "%"),
    ("muscle_pct",
     re.compile(r"\b(?:m[uú]sculo|muscle|masa\s+muscular)\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\s*%?\b", re.IGNORECASE),
     "%"),
    ("basal_metabolic_rate",
     re.compile(r"\b(?:rm|bmr|metabolismo\s+basal|tasa\s+metab[oó]lica)\s*[:=]?\s*(\d{3,5})\b", re.IGNORECASE),
     "kcal"),
    ("bmi",
     re.compile(r"\b(?:imc|bmi)\s*[:=]?\s*(\d{1,2}(?:\.\d{1,2})?)\b", re.IGNORECASE),
     ""),
    ("weight_kg",
     re.compile(r"\b(?:weight|peso)\s*[:=]?\s*(\d{2,3}(?:\.\d{1,2})?)\s*(?:kg|kilos?)?\b", re.IGNORECASE),
     "kg"),
]


def _try_body_composition(text: str) -> HealthIntent | None:
    """Parse multi-field body composition messages like:
        'Musculo 34.5%, RM 1435, weight 64, FAC 18.7%, visceral FAC 8. BMI 25'
    Returns ONE HealthIntent with data.type='body_composition' carrying
    all detected fields. Only returns a match if ≥2 fields are detected
    (single-field like 'peso 65' is handled by _try_vital instead)."""
    fields: dict[str, Any] = {}
    title_parts: list[str] = []
    # Process patterns in order; once a field is matched, mask it out of
    # the remaining text so subsequent patterns don't double-match. This
    # keeps "visceral FAC 8" from also matching as "FAC 8" (body fat).
    remaining = text
    for name, pat, unit in _BODY_FIELD_PATTERNS:
        m = pat.search(remaining)
        if m:
            try:
                v = float(m.group(1))
            except ValueError:
                continue
            fields[name] = v
            label = {
                "visceral_fat": f"visceral {v:g}",
                "body_fat_pct": f"grasa {v:g}%",
                "muscle_pct": f"músculo {v:g}%",
                "basal_metabolic_rate": f"RM {int(v)}",
                "bmi": f"IMC {v:g}",
                "weight_kg": f"peso {v:g} kg",
            }[name]
            title_parts.append(label)
            # Erase what was matched so it doesn't get reused for another
            # field. Use the full match span (not the captured value).
            remaining = remaining[:m.start()] + " " + remaining[m.end():]
    if len(fields) < 2:
        return None
    return HealthIntent(
        kind="vital",
        title="composición: " + ", ".join(title_parts),
        data={"type": "body_composition", **fields},
        confidence=0.85,
    )


def _try_natural_sleep(text: str) -> HealthIntent | None:
    """Parse natural-language sleep like 'me dormí a la una de la madrugada
    y acabo de despertar ahorita'. Returns a sleep_hours vital with the
    computed duration. Falls back to None on ambiguous input.

    Two cases:
      A) Explicit end time: 'desperté a las 8' → end_hour = 8
      B) 'ahorita' / 'recién' → end = now in local TZ at call time
    """
    from datetime import datetime
    from zoneinfo import ZoneInfo
    m = _SLEEP_FROM_TO_RE.search(text)
    if not m:
        return None
    start_h = _parse_hour_token(m.group(1))
    if start_h is None:
        return None
    start_min = int(m.group(2)) if m.group(2) else 0
    period = (m.group(3) or "").lower()       # "noche"|"mañana"|"tarde"|"madrugada"|""
    end_phrase = (m.group(4) or "").lower()
    end_h_token = m.group(5)
    end_min_str = m.group(6)

    # Disambiguate AM/PM from the spoken period when possible.
    # "a la una de la noche/madrugada" → 1:00 AM
    # "a las once de la noche" → 23:00
    # "a las 8 de la mañana" → 8:00
    if period in ("noche", "madrugada"):
        # 1..6 → AM (1-6 AM, madrugada); 7..12 → PM (night)
        if start_h <= 6 or start_h == 12:
            sh24 = start_h if start_h != 12 else 0
        else:
            sh24 = start_h + 12 if start_h < 12 else start_h
    elif period == "tarde":
        sh24 = start_h + 12 if start_h < 12 else start_h
    elif period == "mañana":
        sh24 = start_h if start_h < 12 else 0
    else:
        # No period given. Reasonable default: if start_h <= 6 → AM (early
        # sleep onset = madrugada), else PM (night sleep onset).
        sh24 = start_h if start_h <= 6 else (start_h + 12 if start_h < 12 else start_h)

    # End time: explicit, or now.
    tz = ZoneInfo("America/Mexico_City")  # match the rest of LifeOS default
    now = datetime.now(tz)
    if end_h_token:
        eh_parsed = _parse_hour_token(end_h_token)
        if eh_parsed is None:
            return None
        eh24 = eh_parsed
        em = int(end_min_str) if end_min_str else 0
        # Heuristic: if explicit end_hour < start_hour, assume next day.
        # If no period given for end, assume morning if eh24 ≤ 11.
    elif "ahorita" in end_phrase or "ya" in end_phrase or "recién" in end_phrase:
        eh24 = now.hour
        em = now.minute
    else:
        # Couldn't determine end time
        return None

    # Compute hours, allowing the night to wrap past midnight.
    start_min_total = sh24 * 60 + start_min
    end_min_total = eh24 * 60 + em
    delta = end_min_total - start_min_total
    if delta < 0:
        delta += 24 * 60
    hours = round(delta / 60, 1)
    if hours < 0.5 or hours > 16:  # sanity bounds; outside this is suspicious
        return None
    return HealthIntent(
        kind="vital",
        title=f"dormí {hours}h",
        data={
            "type": "sleep_hours",
            "value": hours,
            "unit": "h",
            "start_hour_24": sh24,
            "start_minute": start_min,
            "end_hour_24": eh24,
            "end_minute": em,
        },
        confidence=0.80,  # natural language → slightly lower
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
    # Bare BP + pulse: "116, 84 y pulso 72" / "116/84 pulso 72". Only fires
    # when the numbers fall in physiological ranges (sys 80-220, dia 40-130,
    # pulse 30-220) to avoid false positives on dimensions/codes/accounting.
    m = _BP_PULSE_BARE_RE.search(text)
    if m:
        sys, dia, pulse = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 80 <= sys <= 220 and 40 <= dia <= 130 and 30 <= pulse <= 220:
            return HealthIntent(
                kind="vital",
                title=f"presión {sys}/{dia}, pulso {pulse}",
                data={"type": "blood_pressure", "systolic": sys, "diastolic": dia,
                      "pulse_bpm": pulse, "unit": "mmHg"},
                confidence=0.80,
            )
    m = _WEIGHT_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital",
            title=f"peso {v} kg",
            data={"type": "weight", "value": v, "unit": "kg"},
        )
    m = _SLEEP_HOURS_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital",
            title=f"dormí {v}h",
            data={"type": "sleep_hours", "value": v, "unit": "h"},
        )
    # Single-field body composition fallbacks. _try_body_composition only
    # fires when ≥2 fields are present, so "Es FAT 18.7" / "RM 1435" alone
    # would otherwise miss. Order matters: visceral BEFORE body_fat to
    # avoid "visceral fat 8" matching the plain fat pattern.
    m = _SINGLE_VISCERAL_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital", title=f"grasa visceral {v:g}",
            data={"type": "visceral_fat", "value": v}, confidence=0.80,
        )
    m = _SINGLE_BODY_FAT_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital", title=f"grasa corporal {v:g}%",
            data={"type": "body_fat_pct", "value": v, "unit": "%"},
            confidence=0.80,
        )
    m = _SINGLE_MUSCLE_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital", title=f"músculo {v:g}%",
            data={"type": "muscle_pct", "value": v, "unit": "%"},
            confidence=0.80,
        )
    m = _SINGLE_BMI_RE.search(text)
    if m:
        v = float(m.group(1))
        return HealthIntent(
            kind="vital", title=f"IMC {v:g}",
            data={"type": "bmi", "value": v}, confidence=0.80,
        )
    m = _SINGLE_RM_RE.search(text)
    if m:
        v = int(m.group(1))
        return HealthIntent(
            kind="vital", title=f"RM {v} kcal",
            data={"type": "basal_metabolic_rate", "value": v, "unit": "kcal"},
            confidence=0.80,
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
# Body composition runs BEFORE _try_vital because:
#   "weight 64, FAC 18.7%, visceral 8, BMI 25" contains 'weight 64' which
#   _try_vital would happily match in isolation, capturing only the weight
#   and dropping the other 3 metrics. _try_body_composition only fires when
#   ≥2 fields are present, so it won't steal single-field inputs.
# Natural-language sleep runs BEFORE _try_vital so 'me dormí a la una y
# desperté ahorita' picks up over the simpler 'dormí N horas' shape.
_PARSERS = (
    _try_body_composition,
    _try_natural_sleep,
    _try_vital,
    _try_symptom,
    _try_medication,
)


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
