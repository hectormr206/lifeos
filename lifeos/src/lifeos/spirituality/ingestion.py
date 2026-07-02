"""Detect spirituality phrases from chat text.

Spirituality entries are nuanced prose. False positives here are worse
than missed entries — a phantom "value" entry created from a casual
sentence is meaningfully wrong in a way a missed gratitude isn't. So
this parser is intentionally CONSERVATIVE: only matches phrases with
clear, unambiguous triggers.

Recognized patterns (v1):
    - "hoy agradezco X" / "agradezco X" → gratitude
    - "medité X minutos"                 → meditation
    - "reflexión: X" (explicit prefix)   → reflection (manual marker)

Everything else (general reflection, values, retros, questions) is
created through the /spirituality UI or the chat reminder system.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.spirituality.ingestion")


@dataclass(frozen=True, slots=True)
class SpiritualityIntent:
    kind: str
    title: str
    body: str | None = None
    data: dict[str, Any] = field(default_factory=dict)
    confidence: float = 0.85


# ─── Gratitude ─────────────────────────────────────────────────────────

# "hoy agradezco X" / "agradezco X" / "estoy agradecid[oa] por X"
# Captures a single thing (the most common shape). For lists like "3 cosas
# que agradezco hoy: A, B y C", the UI form handles them better — the
# regex would over-segment a comma-separated list.
_GRATITUDE_RE = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:hoy\s+|today\s+)?"
    r"(?:agradezco|estoy\s+agradecid[oa]\s+por|"
    r"(?:i'?m\s+|i\s+am\s+)?(?:grateful|thankful)\s+for)\s+"
    r"(?P<what>.+?)"
    r"\s*\.?\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _try_gratitude(text: str) -> SpiritualityIntent | None:
    m = _GRATITUDE_RE.match(text.strip())
    if not m:
        return None
    what = m.group("what").strip()
    if not what or len(what) > 300:
        return None
    # Split commas/y → list items, in case the user did "agradezco A, B y C"
    items = [
        s.strip()
        for s in re.split(r"\s*,\s*|\s+y\s+|\s+and\s+", what)
        if s.strip()
    ]
    title = "Agradezco hoy" if len(items) > 1 else f"Agradezco: {what}"
    return SpiritualityIntent(
        kind="gratitude",
        title=title,
        body=what,
        data={"items": items} if len(items) > 1 else {},
    )


# ─── Meditation ───────────────────────────────────────────────────────

_MEDITATION_RE = re.compile(
    r"\b(?:medit[éeè]|meditated(?:\s+for)?)\s+(\d{1,3})\s*(?:minut[oe]s?|mins?|m)\b",
    re.IGNORECASE,
)


def _try_meditation(text: str) -> SpiritualityIntent | None:
    m = _MEDITATION_RE.search(text)
    if not m:
        return None
    mins = int(m.group(1))
    if not (1 <= mins <= 4 * 60):
        return None
    return SpiritualityIntent(
        kind="meditation",
        title=f"Meditación {mins} min",
        data={"duration_minutes": mins},
    )


# ─── Explicit reflection prefix ───────────────────────────────────────

_REFLECTION_RE = re.compile(
    r"^\s*(?:axi[,:\s]+)?(?:reflexi[oó]n|reflection)\s*:\s*(?P<what>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _try_reflection(text: str) -> SpiritualityIntent | None:
    m = _REFLECTION_RE.match(text.strip())
    if not m:
        return None
    what = m.group("what").strip()
    if not what or len(what) > 1000:
        return None
    # First sentence-ish as title, full text as body.
    title = what.split(".")[0][:200] if "." in what else what[:200]
    return SpiritualityIntent(
        kind="reflection",
        title=title,
        body=what,
    )


_PARSERS = (_try_meditation, _try_reflection, _try_gratitude)


def parse_spirituality(text: str) -> SpiritualityIntent | None:
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("spirituality parser %s crashed: %s", parser.__name__, e)
    return None
