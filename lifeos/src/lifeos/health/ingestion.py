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
    # EN: "glucose 110", "blood sugar 95 this morning".
    r"\b(?:glucos[aoe]|blood\s+sugar)\b[^.\n,;:]{0,25}?\s(\d{2,3})(?:\s*mg/?d?l)?\b",
    re.IGNORECASE,
)
# Two BP shapes:
#   (1) "presión 120/80" — explicit keyword
#   (2) "120/80" or "116, 84" with optional "y pulso N" appended — bare numbers
#       only triggers when the numbers fall in physiological ranges to avoid
#       false positives on accounting/dimensions/codes.
# Shared keyword alternations (ES + EN) so all BP variants stay in sync.
_BP_KEYWORD_ALT = r"presi[oó]n(?:\s+arterial)?|p\.?a\.?|blood\s+pressure|bp"
_PULSE_KEYWORD_ALT = r"pulsos?|pulse|fc|frecuencia\s+card[íi]aca|hr|heart\s+rate"
# Separator between systolic and diastolic: "/", "over" (EN), or plain space
# (output of the normalize_numbers_es word→digit pass).
_BP_SEP = r"(?:/\s*|\s+over\s+|\s+)"

_BP_RE_WITH_PULSE = re.compile(
    # "presión 120/80 pulso 72" / "presión 122 81, 53 pulsos" — keyword + sys/dia
    # + optional pulse. Separator between sys and dia: "/", "over", or space.
    # Pulse follows after optional separator and pulse keyword OR as bare number
    # with "pulsos?". EN: "blood pressure 120 over 80, pulse 72".
    rf"\b(?:{_BP_KEYWORD_ALT})\s*(?:de|:)?\s*"
    rf"(?P<bpws>\d{{2,3}})\s*{_BP_SEP}(?P<bpwd>\d{{2,3}})"
    rf"(?:[,;]?\s*(?:y\s+|and\s+)?(?:(?:{_PULSE_KEYWORD_ALT})\s*(?:of\s+)?[:=]?\s*(?P<bpwp1>\d{{2,3}})"
    r"|(?P<bpwp2>\d{2,3})\s*pulsos?))?",
    re.IGNORECASE,
)
_BP_RE = re.compile(
    # Explicit keyword + digits. Separator between sys and dia can be "/" (typed),
    # "over" (EN), or a plain space (output of normalize_numbers_es).
    rf"\b(?:{_BP_KEYWORD_ALT})\s*(?:de|:)?\s*"
    rf"(\d{{2,3}})\s*{_BP_SEP}(\d{{2,3}})\b",
    re.IGNORECASE,
)
_BP_PULSE_BARE_RE = re.compile(
    # "116, 84 y pulso 72"  /  "116/84 pulso 72"  /  "116, 84 pulso 72"
    # /  "132/83, pulsos 58" (plural) / "120/80 with a pulse of 65" (EN).
    # Both sides have to be plausible (sys >= 80; dia >= 40) to avoid eating
    # "150, 200" type non-medical numbers — checked in Python.
    # Separator between sys and dia: comma, slash, "over", or plain space (the
    # last covers normalize_numbers_es output from word-form BP phrases).
    r"^\s*(\d{2,3})(?:\s*[,/]\s*|\s+over\s+|\s+)(\d{2,3})"
    r"(?:\s+y\s+|\s+and\s+|\s+with\s+a\s+|\s*,?\s+|\s*[.;]\s+)?"
    rf"(?:{_PULSE_KEYWORD_ALT})\s*(?:of\s+)?[:=]?\s*(\d{{2,3}})\b",
    re.IGNORECASE,
)
_BP_PULSE_TRAILING_RE = re.compile(
    # Pulse number BEFORE the word: "132, 83, 58 pulsos" / "118, 83, 52
    # pulsos." — three bare numbers (sys, dia, pulse) closed by "pulso(s)".
    # Also handles "122/81 53 pulsos" and "122 81 53 pulsos" (space-sep output
    # from normalize_numbers_es word→digit pass).
    # The first separator (sys→dia) allows comma, slash, or plain space [,/ ];
    # the second separator (dia→pulse) is also wide: comma, slash, or space.
    # Same physiological plausibility gate applies (checked in Python).
    r"^\s*(\d{2,3})\s*[,/ ]\s*(\d{2,3})\s*[,/ ]\s*(\d{2,3})\s*pulsos?\b",
    re.IGNORECASE,
)
_BP_PULSE_DE_PULSO_RE = re.compile(
    # "113, 82 y 55 de pulso." / "120, 80 y 60 de pulsos." /
    # "120, 80 y 60 de pulsaciones." / "122 81 y 53 de pulsaciones." —
    # pulse number comes before "de pulso(s)" or "de pulsaciones".
    # Separator between sys and dia: comma, slash, or plain space.
    r"^\s*(\d{2,3})\s*[,/ ]\s*(\d{2,3})"
    r"(?:\s*,?\s+y\s+|\s*,\s+|\s+)"
    r"(\d{2,3})\s+de\s+pulsaciones?\b",
    re.IGNORECASE,
)
_BP_PULSE_DE_PULSO_WORD_RE = re.compile(
    # Same shape but ends with "de pulso" or "de pulsos" (no "pulsaciones").
    # Separator between sys and dia: comma, slash, or plain space.
    r"^\s*(\d{2,3})\s*[,/ ]\s*(\d{2,3})"
    r"(?:\s*,?\s+y\s+|\s*,\s+|\s+)"
    r"(\d{2,3})\s+de\s+pulsos?\b",
    re.IGNORECASE,
)
_WEIGHT_RE = re.compile(
    # "peso 75", "peso de 70.5kg", "me pesé/pese 65", "pesé 65", "weight 64",
    # "my weight is 64", "I weigh 64".
    # `pes[éeo]` allows past tense with/without accent and present "me peso".
    # Also matches standalone "pesé N" without "me" (e.g. voice dictation).
    r"\b(?:peso(?:\s+actual)?|(?:me\s+)?pes[éeo]|(?:my\s+)?weight(?:\s+is)?"
    r"|(?:i\s+)?weigh(?:ed)?)\s*(?:de|:|=)?\s*"
    r"(\d{2,3}(?:\.\d{1,2})?)\s*(kg|kilos?)?\b",
    re.IGNORECASE,
)
_SLEEP_HOURS_RE = re.compile(
    # "dormí 6 horas", "dormí 6.5 horas", "dormí 6 horas y media",
    # "slept 7 hours", "slept 7 and a half hours" ("and a half" → +0.5,
    # handled in _try_vital the same way as "y media").
    r"\b(?:dorm[íi]|(?:i\s+)?slept)\s*(?:unas?\s+|about\s+|around\s+)?"
    r"(\d{1,2}(?:\.\d{1,2})?)\s*"
    r"(?:and\s+a\s+half\s+)?(?:horas?|hrs?|hours?|h)"
    r"(?:\s+y\s+media)?\b",
    re.IGNORECASE,
)
# Spanish number words 1-12 for clock hours. "media" handled separately.
_SP_HOUR_WORDS = {
    "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
    "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
}
# "una" pulls double duty as the indefinite article ("una hora") and the
# number 1. We only accept it in the clock context here.

# Natural-language sleep with named groups for readability. Handles:
#   me dormí / me acosté / me fui a dormir|cama
#     (a/como a las) X (:MM | y media | y cuarto | y N)
#       (de la noche/mañana/tarde/madrugada | am | pm | h)
#   ... desperté/me levanté/acabo de despertar(me)/levantarme
#   (ahorita | a las Y (:MM | y media | y cuarto | y N))
#
# Also handles: "dormí de X (a|hasta) Y"
_HOUR_WORD_ALT = "|".join(_SP_HOUR_WORDS.keys())
# Shared hour+minute fragment used in both onset and end groups.
_HOUR_MIN_FRAG = (
    rf"(?P<{{h}}>\d{{{{1,2}}}}|{_HOUR_WORD_ALT})"
    r"(?:"
    r"  :(?P<{min_d}>\d{2})"
    r"  | \s+y\s+(?P<{min_w}>media|cuarto|\d{1,2})"
    r")?"
)

# Spoken day-period vocabulary (ES + EN). EN words are normalized to their ES
# equivalents inside _resolve_hour_24 so the clock-resolution machinery is
# shared. Prefixes: "de la" (ES), "at"/"in the" (EN: "at night", "in the
# morning").
_PERIOD_WORD_ALT = r"noche|ma[ñn]ana|tarde|madrugada|night|morning|afternoon|evening"
_PERIOD_PREFIX = r"(?:de\s+la\s+|at\s+|in\s+the\s+)"

_SLEEP_FROM_TO_RE = re.compile(
    # Onset verb: "me dormí", "me acosté", "me fui a dormir|cama",
    # EN: "went to bed", "went to sleep", "fell asleep"
    r"\b(?:me\s+(?:dorm[íi]|acost[eé])|me\s+fui\s+a\s+(?:dormir|la\s+cama)"
    r"|went\s+to\s+(?:bed|sleep)|fell\s+asleep)\s*"
    r"(?:como\s+)?(?:a\s+|at\s+)?(?:la\s+|las\s+)?"
    rf"(?P<start_h>\d{{1,2}}|{_HOUR_WORD_ALT})"
    r"(?:"
    r"  :(?P<start_min>\d{2})"
    r"  | \s+y\s+(?P<start_min_word>media|cuarto|\d{1,2})"
    r")?\s*"
    rf"(?:{_PERIOD_PREFIX}(?P<period>{_PERIOD_WORD_ALT})|(?P<ampm>am|pm))?"
    r".{1,120}?"
    # Wake verb: desperté, me levanté, acabo de despertar(me)|levantarme,
    # EN: woke up, got up
    r"(?:desp[eé]rt[éo]|me\s+levant[éo]|acabo\s+de\s+(?:despertar(?:me)?|levantarme)"
    r"|woke\s+up|got\s+up)"
    r"(?:.{0,40}?"
    r"(?:"
    r"  (?P<now>ahorita|ya|reci[eé]n|just\s+now)"
    r"  | (?:a|at)\s+(?:la\s+|las\s+)?"
    rf"   (?P<end_h>\d{{1,2}}|{_HOUR_WORD_ALT})"
    r"  (?:"
    r"    :(?P<end_min>\d{2})"
    r"    | \s+y\s+(?P<end_min_word>media|cuarto|\d{1,2})"
    r"  )?"
    rf"  (?:\s*(?:{_PERIOD_PREFIX}(?P<end_period>{_PERIOD_WORD_ALT})|(?P<end_ampm>am|pm)))?"
    r"))?",
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)

# "dormí de X a Y" / "dormí de X hasta Y" / EN "slept from X to|until Y"
_SLEEP_DE_X_A_Y_RE = re.compile(
    r"\b(?:dorm[íi]\s+de|slept\s+from)\s+(?:la\s+|las\s+)?"
    rf"(?P<start_h>\d{{1,2}}|{_HOUR_WORD_ALT})"
    r"(?:"
    r"  :(?P<start_min>\d{2})"
    r"  | \s+y\s+(?P<start_min_word>media|cuarto|\d{1,2})"
    r")?\s*"
    rf"(?:{_PERIOD_PREFIX}(?P<period>{_PERIOD_WORD_ALT})|(?P<ampm>am|pm))?"
    r"\s+(?:a|hasta|to|until|till)\s+(?:la\s+|las\s+)?"
    rf"(?P<end_h>\d{{1,2}}|{_HOUR_WORD_ALT})"
    r"(?:"
    r"  :(?P<end_min>\d{2})"
    r"  | \s+y\s+(?P<end_min_word>media|cuarto|\d{1,2})"
    r")?"
    rf"(?:\s*(?:{_PERIOD_PREFIX}(?P<end_period>{_PERIOD_WORD_ALT})|(?P<end_ampm>am|pm)))?",
    re.IGNORECASE | re.VERBOSE,
)


# Module-level compiled regexes for _parse_duration_es (FIX 8: avoids
# re-compilation on every call; FIX 7: sleep-vocab guard).
# Note: \b does not work correctly around non-ASCII chars (ñ, í, é) in Python
# regex when using the default ASCII flag. We use a plain substring search via
# re.search (which does not require word-boundary anchors to be reliable here)
# since the vocabulary is domain-specific and won't produce false positives in
# exercise contexts.
_DURATION_SLEEP_VOCAB_RE = re.compile(
    r"(?:dorm[íi]|durm[íi]|acost[eé]|despert[oé]|sue[ñn]|noche"
    r"|slept|asleep|woke\s+up|went\s+to\s+bed)",
    re.IGNORECASE,
)
_DURATION_MINUTES_RE = re.compile(r"\b(\d{1,3})\s+min(?:utos?)?\b", re.IGNORECASE)
_DURATION_COMPOUND_RE = re.compile(
    r"\b(\d{1,2})\s+hora(?:s)?\s+(\d{1,3})\s+min(?:utos?)?\b",
    re.IGNORECASE,
)


def _parse_minutes_word(tok: str | None) -> int:
    """Convert 'media' → 30, 'cuarto' → 15, '20' → 20. Returns 0 on None."""
    if not tok:
        return 0
    tok = tok.strip().lower()
    if tok == "media":
        return 30
    if tok == "cuarto":
        return 15
    if tok.isdigit():
        n = int(tok)
        return n if 0 <= n <= 59 else 0
    return 0


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


# Plausibility ranges per body-composition metric. Used to reject obvious
# mis-parses (e.g., "FAT 64" can't be 64% body fat — likely the user meant
# something else or there's a typo). If a value falls outside, we DROP just
# that field; we don't reject the whole entry.
_BODY_FIELD_RANGES: dict[str, tuple[float, float]] = {
    "visceral_fat": (1, 60),                  # Inbody-style integer 1-30 typical
    "body_fat_pct": (1, 70),                  # %
    "muscle_pct": (1, 70),                    # %
    "basal_metabolic_rate": (600, 4000),      # kcal/day
    "bmi": (10, 60),                          # kg/m²
    "weight_kg": (25, 300),                   # kg
}


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
            # Plausibility check — drop the field if value is outside
            # physiological range (likely a typo / mis-parse).
            lo, hi = _BODY_FIELD_RANGES.get(name, (-1e9, 1e9))
            if not (lo <= v <= hi):
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


def _resolve_hour_24(h: int, period: str, ampm: str, wake: bool = False) -> int:
    """Convert a 12-hour token + spoken period or am/pm marker to 24h.

    period: 'noche'|'madrugada'|'tarde'|'mañana'|'' (EN 'night'|'morning'|
            'afternoon'|'evening' are normalized to their ES equivalents)
    ampm:   'am'|'pm'|''
    wake:   True when resolving the wake-up end time (heuristic differs from onset)
    """
    p = period.lower().strip()
    # Normalize EN period words to the ES vocabulary so the resolution rules
    # below stay single-sourced.
    p = {
        "night": "noche",
        "morning": "mañana",
        "afternoon": "tarde",
        "evening": "tarde",
    }.get(p, p)
    a = ampm.lower().strip()
    if a == "pm":
        return h + 12 if h < 12 else h
    if a == "am":
        return h if h != 12 else 0
    if p == "madrugada":
        # madrugada: h <= 6 stay AM; 12 → midnight; others + 12
        if h <= 6:
            return h
        if h == 12:
            return 0
        return h + 12 if h < 12 else h
    if p == "noche":
        # noche: h <= 3 treated as madrugada-style AM (e.g. "3 de la noche" = 3:00)
        # h 4-11 → PM (+ 12); h == 12 → midnight (0)
        if h <= 3:
            return h
        if h == 12:
            return 0
        return h + 12 if h < 12 else h
    if p == "tarde":
        return h + 12 if h < 12 else h
    if p in ("mañana",):
        # h == 12 with "de la mañana" → noon (12:00), not midnight
        return h if h <= 12 else 0
    if wake:
        # Wake-up heuristic: no period given. Hours 1-12 are assumed morning (AM).
        # Hours 13-23 are already in 24h form (rare but valid).
        return h if h <= 12 else h
    # Sleep-onset heuristic: h ≤ 6 → AM (madrugada), else PM (evening).
    return h if h <= 6 else (h + 12 if h < 12 else h)


def _parse_duration_es(text: str) -> int | None:
    """Parse a Spanish exercise-duration phrase and return total minutes.

    Reuses _parse_hour_token and _parse_minutes_word — no new number parser.

    Handles:
      "media hora"              → 30
      "cuarto de hora"          → 15
      "45 minutos"              → 45
      "30 minutos"              → 30
      "una hora"                → 60
      "2 horas"                 → 120
      "hora y media"            → 90
      "una hora y media"        → 90
      "1 hora y cuarto"         → 75
      "una hora y cuarto"       → 75
      "una hora y 20"           → 80
      "2 horas 30 minutos"      → 150  (compound: hours + bare minutes)
      "1 hora 15 minutos"       → 75   (compound)

    Returns None when:
      - no duration phrase is found
      - the value is outside the plausible range (1..1440 minutes)
      - the text contains sleep-onset vocabulary (FIX 7: guard against
        misclassified sleep phrases producing bogus exercise durations)
    """
    if not text or not isinstance(text, str):
        return None

    t = text.lower().strip()

    # ── FIX 7: sleep-vocab guard ─────────────────────────────────────────
    # If the text contains sleep-onset vocabulary, this is not an exercise
    # duration phrase even if it contains hour/minute numbers.
    if _DURATION_SLEEP_VOCAB_RE.search(t):
        return None

    # ── "media hora" (alone or with other text) ─────────────────────────
    if re.search(r"\bmedia\s+hora\b", t):
        return 30

    # ── "cuarto de hora" ─────────────────────────────────────────────────
    if re.search(r"\bcuarto\s+de\s+hora\b", t):
        return 15

    # ── FIX 4: compound "N horas M minutos" ──────────────────────────────
    # Must be checked BEFORE the standalone "N minutos" branch so the
    # trailing minutes don't return early and drop the hours component.
    mc = _DURATION_COMPOUND_RE.search(t)
    if mc:
        h_val = int(mc.group(1))
        m_val = int(mc.group(2))
        total = h_val * 60 + m_val
        return total if 1 <= total <= 1440 else None

    # ── "N hora(s) [y <min_word>]" ───────────────────────────────────────
    # Matches: "una hora", "2 horas", "hora y media", "1 hora y cuarto"
    _HOUR_ALT = "|".join(_SP_HOUR_WORDS.keys())
    hour_re = re.compile(
        rf"\b({_HOUR_ALT}|\d{{1,2}})\s+hora(?:s)?"
        r"(?:\s+y\s+(media|cuarto|\d{1,2}))?\b",
        re.IGNORECASE,
    )
    m = hour_re.search(t)
    if m:
        hour_tok = m.group(1)
        hour_val = _parse_hour_token(hour_tok)
        if hour_val is not None:
            min_word = m.group(2)  # may be None
            total = hour_val * 60 + _parse_minutes_word(min_word)
            return total if 1 <= total <= 1440 else None

    # Also handle bare "hora y media" / "hora y cuarto" without a number prefix
    m2 = re.search(r"\bhora(?:s)?\s+y\s+(media|cuarto|\d{1,2})\b", t)
    if m2:
        min_word = m2.group(1)
        total = 60 + _parse_minutes_word(min_word)
        return total if 1 <= total <= 1440 else None

    # ── "N minutos" / "N mins" ───────────────────────────────────────────
    mm = _DURATION_MINUTES_RE.search(t)
    if mm:
        minutes = int(mm.group(1))
        if 1 <= minutes <= 1440:
            return minutes

    return None


def _validate_amount(raw_text: str | None, nano_amount: float | None) -> float | None:
    """Conservative validate-and-skip guard for finance amounts.

    Returns nano_amount when it falls within plausible bounds (>0 and <= 1e9).
    Returns None when the amount is implausible or unparseable.

    This is a VALIDATION layer, not a re-parser. When None is returned the
    caller should not silently trust the nano value — but should also not
    aggressively re-parse to avoid false overrides (design ADR-conservative).
    """
    if nano_amount is None:
        return None
    try:
        v = float(nano_amount)
    except (TypeError, ValueError):
        return None
    # Conservative bounds: positive and below one billion
    if v <= 0 or v >= 1_000_000_000:
        return None
    return v


def _try_natural_sleep(
    text: str,
    now: "datetime | None" = None,  # injectable for tests and dashboard
) -> "HealthIntent | None":
    """Parse natural-language sleep phrases. Returns a sleep_hours vital or None.

    Handles:
      • me dormí / me acosté / me fui a dormir  … desperté/me levanté/acabo de despertar
      • dormí de X a Y / dormí de X hasta Y

    `now` lets callers pass the original send timestamp instead of wall time.
    Defaults to datetime.now(Mexico_City) when None.
    """
    from datetime import datetime
    from zoneinfo import ZoneInfo
    tz = ZoneInfo("America/Mexico_City")
    if now is None:
        now = datetime.now(tz)
    elif now.tzinfo is not None:
        # Caller passed a tz-aware datetime (e.g. UTC from the dashboard).
        # Convert to local time so hour/minute reflect CDMX, not UTC.
        now = now.astimezone(tz)

    # ── Try "dormí de X a Y" first (no onset verb needed) ────────────────
    m2 = _SLEEP_DE_X_A_Y_RE.search(text)
    if m2:
        start_h = _parse_hour_token(m2.group("start_h"))
        end_h_tok = m2.group("end_h")
        end_h = _parse_hour_token(end_h_tok) if end_h_tok else None
        if start_h is not None and end_h is not None:
            start_min = (int(m2.group("start_min")) if m2.group("start_min")
                         else _parse_minutes_word(m2.group("start_min_word")))
            end_min = (int(m2.group("end_min")) if m2.group("end_min")
                       else _parse_minutes_word(m2.group("end_min_word")))
            period = (m2.group("period") or "").lower()
            ampm = (m2.group("ampm") or "").lower()
            end_period = (m2.group("end_period") or "").lower()
            end_ampm = (m2.group("end_ampm") or "").lower()
            sh24 = _resolve_hour_24(start_h, period, ampm)
            eh24 = _resolve_hour_24(end_h, end_period, end_ampm, wake=True)
            delta = (eh24 * 60 + end_min) - (sh24 * 60 + start_min)
            if delta < 0:
                delta += 24 * 60
            hours = round(delta / 60, 2)
            if 0.5 <= hours <= 16:
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
                        "end_minute": end_min,
                    },
                    confidence=0.80,
                )

    # ── Try "me dormí / me acosté / me fui a dormir … desperté …" ────────
    m = _SLEEP_FROM_TO_RE.search(text)
    if not m:
        return None
    start_h = _parse_hour_token(m.group("start_h"))
    if start_h is None:
        return None
    start_min = (int(m.group("start_min")) if m.group("start_min")
                 else _parse_minutes_word(m.group("start_min_word")))
    period = (m.group("period") or "").lower()
    ampm = (m.group("ampm") or "").lower()
    end_phrase = (m.group("now") or "").lower()
    end_h_token = m.group("end_h")
    end_min_str = m.group("end_min")
    end_min_word = m.group("end_min_word")

    sh24 = _resolve_hour_24(start_h, period, ampm)

    # End time: explicit clock, "ahorita/ya/recién" (= now), or bare wake verb
    # with no time qualifier — in the last case we use `now` as the wake time.
    if end_h_token:
        eh_parsed = _parse_hour_token(end_h_token)
        if eh_parsed is None:
            return None
        end_period = (m.group("end_period") or "").lower()
        end_ampm = (m.group("end_ampm") or "").lower()
        eh24 = _resolve_hour_24(eh_parsed, end_period, end_ampm, wake=True)
        em = (int(end_min_str) if end_min_str
              else _parse_minutes_word(end_min_word))
    else:
        # "ahorita"/"ya"/"recién" OR bare wake verb with no end time → use now
        eh24 = now.hour
        em = now.minute

    # Compute hours, allowing the night to wrap past midnight.
    start_min_total = sh24 * 60 + start_min
    end_min_total = eh24 * 60 + em
    delta = end_min_total - start_min_total
    if delta < 0:
        delta += 24 * 60
    hours = round(delta / 60, 2)
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
    # Keyword BP with optional pulse: "presión 122 81, 53 pulsos".
    m = _BP_RE_WITH_PULSE.search(text)
    if m:
        sys, dia = int(m.group("bpws")), int(m.group("bpwd"))
        pulse_raw = m.group("bpwp1") or m.group("bpwp2")
        if pulse_raw is not None:
            pulse = int(pulse_raw)
            if 80 <= sys <= 220 and 40 <= dia <= 130 and 30 <= pulse <= 220:
                return HealthIntent(
                    kind="vital",
                    title=f"presión {sys}/{dia}, pulso {pulse}",
                    data={"type": "blood_pressure", "systolic": sys, "diastolic": dia,
                          "pulse_bpm": pulse, "unit": "mmHg"},
                    confidence=0.80,
                )
        # Fallback: keyword with only sys/dia, no pulse.
        return HealthIntent(
            kind="vital",
            title=f"presión {sys}/{dia}",
            data={"type": "blood_pressure", "systolic": sys, "diastolic": dia,
                  "unit": "mmHg"},
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
    # Bare BP + pulse: "116, 84 y pulso 72" / "116/84 pulso 72" /
    # "122/81 53 pulsos" / "113, 82 y 55 de pulso." etc.  Only fires when
    # numbers fall in physiological ranges (sys 80-220, dia 40-130, pulse
    # 30-220) to avoid false positives on dimensions/codes/accounting.
    m = (
        _BP_PULSE_BARE_RE.search(text)
        or _BP_PULSE_TRAILING_RE.search(text)
        or _BP_PULSE_DE_PULSO_WORD_RE.search(text)
        or _BP_PULSE_DE_PULSO_RE.search(text)
    )
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
        # Plausibility: 25-300 kg. Outside this is almost certainly not a
        # body-weight value (e.g. someone writing 'weight 500' as a typo).
        if 25 <= v <= 300:
            return HealthIntent(
                kind="vital",
                title=f"peso {v} kg",
                data={"type": "weight", "value": v, "unit": "kg"},
            )
    m = _SLEEP_HOURS_RE.search(text)
    if m:
        v = float(m.group(1))
        # "dormí 6 horas y media" / "slept 7 and a half hours" → add 0.5; the
        # regex matched the optional half-hour tail so check the matched text.
        matched = m.group(0).lower()
        if "y media" in matched or "and a half" in matched:
            v += 0.5
        # Plausibility: explicit sleep hours must be in a physiological range.
        # Values below 0.5h or above 16h are almost certainly mis-parses or
        # typos — mirrors the sanity gate in _try_natural_sleep.
        if v < 0.5 or v > 16:
            return None
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
    r"\b(?:(?:me\s+)?tom[éeè]|(?:i\s+)?took)\s+"
    r"(?:una\s+|un\s+|la\s+|el\s+|mi\s+|a\s+|an\s+|the\s+|my\s+|some\s+)?"
    r"(?:dosis\s+de\s+|pastilla\s+de\s+|dose\s+of\s+|pill\s+of\s+"
    # "500mg of paracetamol" / "500 mg de paracetamol" — absorb the dose so
    # the captured name is the actual medication.
    r"|\d+\s*(?:mg|mcg|g|ml|ui)\s+(?:of|de)\s+)?"
    r"([a-záéíóúñü0-9\s\-]+?)"
    # Terminators are whole words (\b) so "para" never cuts inside
    # "paracetamol" and "for" never cuts inside "formula".
    r"(?:\s+(?:de|para|porque|por|hace|antes|despu[ée]s|esta|hoy|ayer"
    r"|for|because|before|after|this|today|yesterday|tonight|at|in|to|and|with"
    r"|an\s+hour)\b|[,.;]|$)",
    re.IGNORECASE,
)
# Common Spanish/English objects that follow "tomé"/"took" but aren't medicine.
_TOMÉ_FALSE_POSITIVES = {
    "agua", "café", "cafe", "té", "te", "leche", "jugo", "vino",
    "cerveza", "refresco", "el sol", "una foto", "el bus", "el tren",
    "una decisión", "una decision", "tiempo", "nota",
    # EN — determiners are stripped by _MED_RE, so bare nouns; the article'd
    # variants are kept too as a defensive net.
    "shower", "a shower", "break", "a break", "nap", "a nap",
    "bus", "the bus", "train", "the train", "taxi", "a taxi",
    "photo", "a photo", "picture", "a picture", "walk", "a walk",
    "seat", "a seat", "look", "a look", "call", "a call",
    "note", "a note", "chance", "a chance",
    "breath", "a breath", "deep breath", "a deep breath",
    "decision", "a decision", "day off", "the day off",
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


def parse_health(
    text: str,
    now: "datetime | None" = None,
) -> "HealthIntent | None":
    """Try to extract a health entry from `text`. Returns None on no match.

    `now` is passed to natural-sleep parsers so dashboard can supply the
    original client send time instead of wall time.

    Caller falls back to the brain for everything that returns None. The
    rule is "high precision over high recall": false positives in a
    health log are worse than missed entries (which the user can add
    manually anyway).
    """
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            if parser is _try_natural_sleep:
                res = parser(text, now=now)
            else:
                res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("health parser %s crashed: %s", parser.__name__, e)
    return None
