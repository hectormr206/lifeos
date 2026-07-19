"""Family-subject marker detection, shared by health + exercise ingestion.

Convention (user-defined): the person an entry belongs to is stated at the
START or END of the message; unmarked text is the user themself.

    "Mi esposa tuvo 121, 79, 61 pulsos"   → subject "esposa", remainder parses
    "108, 72, 66 pulsos de mi esposa"     → subject "esposa"
    "My wife slept 7 hours"              → subject "esposa"

Design: detect + STRIP the marker, then let the existing (unchanged) domain
grammars parse the remainder. The subject is the canonical Spanish relation
word so ES/EN and synonyms ("mujer"/"wife") collapse into one label that the
graph layer can resolve against the hub's typed relation edges.

Proper-name markers ("Ana tuvo …") are deliberately NOT supported in v1:
without a roster of known names the pattern "<Word> tuvo" is far too
false-positive-prone (any capitalized sentence start). Precision-first.

Public:
    detect_subject(text) → SubjectMatch | None
    detect_query_subject(query) → str | None
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Canonical ES relation label per accepted marker word. Keys are matched
# case-insensitively; accent variants are listed explicitly so dictation
# without accents ("mi mama") still matches.
_RELATION_CANON: dict[str, str] = {
    # ES
    "esposa": "esposa", "mujer": "esposa",
    "esposo": "esposo", "marido": "esposo",
    "mamá": "mamá", "mama": "mamá", "madre": "mamá",
    "papá": "papá", "papa": "papá", "padre": "papá",
    "hijo": "hijo", "hija": "hija",
    "hermano": "hermano", "hermana": "hermana",
    "abuelo": "abuelo", "abuela": "abuela",
    "suegro": "suegro", "suegra": "suegra",
    "tío": "tío", "tio": "tío", "tía": "tía", "tia": "tía",
    "primo": "primo", "prima": "prima",
    "novio": "novio", "novia": "novia",
    # EN → canonical ES label (single vocabulary downstream)
    "wife": "esposa", "husband": "esposo",
    "mom": "mamá", "mother": "mamá",
    "dad": "papá", "father": "papá",
    "son": "hijo", "daughter": "hija",
    "brother": "hermano", "sister": "hermana",
}

_RELATION_ALT = "|".join(
    sorted((re.escape(k) for k in _RELATION_CANON), key=len, reverse=True)
)

# Verbs that may follow a LEADING marker ("Mi esposa TUVO 96…"). They are
# captured separately so callers can retry parsing without the verb when the
# remainder grammar is start-anchored (e.g. the bare blood-pressure triple).
# Third-person ES + simple-past EN forms only — precision over recall.
_VERB_ALT = (
    r"tuvo|tiene|ten[íi]a|trae|anda\s+con|midi[oó]|se\s+midi[oó]|marc[oó]"
    r"|registr[oó]|pes[oó]|se\s+pes[oó]|dijo|durmi[oó]|hizo|se\s+tom[oó]|tom[oó]"
    r"|had|has|got|did|took|measured|weighed|slept|said|is|was"
)

# Leading: "mi esposa [tuvo] …" / "my wife [had] …" — anchored at the start.
_LEADING_RE = re.compile(
    rf"^\s*(?:mi|my)\s+(?P<rel>{_RELATION_ALT})\b"
    rf"(?:\s+(?P<verb>{_VERB_ALT})\b)?"
    r"[\s:,]*",
    re.IGNORECASE,
)

# Trailing: "… de mi esposa" / "… of my wife" — anchored at the end
# (optional closing punctuation tolerated).
_TRAILING_RE = re.compile(
    rf"[\s,;]*\b(?:de|of)\s+(?:mi|my)\s+(?P<rel>{_RELATION_ALT})\s*[.!?]?\s*$",
    re.IGNORECASE,
)

# Query-oriented: a possessive family marker ANYWHERE in a free-form question
# ("¿cómo estaba mi esposa ayer?", "la presión de mi esposa"). Unanchored, so
# it catches mid-sentence markers the start/end-anchored regexes above miss.
# The required "mi|my" possessive is the false-positive guard: a self query
# with no relation word ("mi presión", "resumen de salud") never matches.
_QUERY_RE = re.compile(
    rf"\b(?:mi|my)\s+(?P<rel>{_RELATION_ALT})\b",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class SubjectMatch:
    subject: str                     # canonical relation label ("esposa")
    remainder: str                   # text with the marker stripped
    remainder_no_verb: str | None    # leading form with the verb ALSO stripped


# Canonical ES relation label → English relation word, for confirmation copy
# in English installs ("your wife"). Spanish uses the canonical label directly.
_EN_RELATION: dict[str, str] = {
    "esposa": "wife", "esposo": "husband",
    "mamá": "mom", "papá": "dad",
    "hijo": "son", "hija": "daughter",
    "hermano": "brother", "hermana": "sister",
    "abuelo": "grandpa", "abuela": "grandma",
    "suegro": "father-in-law", "suegra": "mother-in-law",
    "tío": "uncle", "tía": "aunt",
    "primo": "cousin", "prima": "cousin",
    "novio": "boyfriend", "novia": "girlfriend",
}


def subject_possessive(subject: str, *, en: bool = False) -> str:
    """Possessive phrasing for a family subject, for chat confirmations.

    ``subject_possessive("esposa")`` → ``"tu esposa"``;
    ``subject_possessive("esposa", en=True)`` → ``"your wife"``. Unknown labels
    are passed through as-is ("tu <label>" / "your <label>").
    """
    rel = (subject or "").strip()
    if en:
        return f"your {_EN_RELATION.get(rel.lower(), rel)}"
    return f"tu {rel}"


def _canon(rel: str) -> str:
    return _RELATION_CANON[rel.lower()]


def detect_subject(text: str) -> SubjectMatch | None:
    """Detect a family-subject marker at the start or end of *text*.

    Returns the canonical subject plus the marker-stripped remainder(s), or
    None when the text is unmarked (→ the entry belongs to the user)."""
    if not text or not isinstance(text, str):
        return None

    m = _LEADING_RE.match(text)
    if m:
        remainder_no_verb = None
        if m.group("verb"):
            # remainder keeps the verb (some grammars key off it, e.g.
            # "slept 7 hours"); remainder_no_verb drops it for start-anchored
            # grammars (e.g. "121, 79, 61 pulsos").
            verb_start = m.start("verb")
            remainder = text[verb_start:].strip()
            remainder_no_verb = text[m.end():].strip()
        else:
            remainder = text[m.end():].strip()
        if remainder or remainder_no_verb:
            return SubjectMatch(
                subject=_canon(m.group("rel")),
                remainder=remainder,
                remainder_no_verb=remainder_no_verb or None,
            )

    m = _TRAILING_RE.search(text)
    if m:
        remainder = text[:m.start()].strip()
        if remainder:
            return SubjectMatch(
                subject=_canon(m.group("rel")),
                remainder=remainder,
                remainder_no_verb=None,
            )
    return None


def detect_query_subject(query: str) -> str | None:
    """Detect the family subject a free-form *query* is about.

    Unlike ``detect_subject`` (which strips a start/end marker from a stored
    entry), this scans the whole query for a possessive family marker
    ("mi esposa", "my wife") in any position and returns the canonical
    relation label ("esposa"), or None when the query is about the user
    themself. Used to decide the recall/search subject; None → self.
    """
    if not query or not isinstance(query, str):
        return None
    m = _QUERY_RE.search(query)
    return _canon(m.group("rel")) if m else None
