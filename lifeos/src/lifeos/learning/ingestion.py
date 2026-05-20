"""Detect learning phrases from chat text.

Conservative on purpose: book/course titles need QUOTES so we don't pick
up arbitrary capitalized words. Ideas + research questions need an
EXPLICIT PREFIX. The /learning form handles everything else.

Recognized patterns:
    "empecé el libro 'X'" / "estoy leyendo 'X'"           → book (status=active)
    "terminé el libro 'X'" / "leí 'X'"                     → book (status=done)
    "empecé el curso de 'X'" / "estoy estudiando 'X'"      → course (status=active)
    "idea: X"                                              → idea
    "investigar: X" / "tengo que investigar X"             → research_question
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.learning.ingestion")


@dataclass(frozen=True, slots=True)
class LearningIntent:
    kind: str
    title: str
    status: str = "active"
    body: str | None = None
    author: str | None = None
    data: dict[str, Any] = field(default_factory=dict)
    confidence: float = 0.85


# Quoted titles: accept ASCII " ' and typographic " " « ».
_QUOTED_TITLE = r"""['"«“‘](?P<title>[^'"»”’]{1,200})['"»”’]"""


# ─── Books ────────────────────────────────────────────────────────────

_BOOK_START_RE = re.compile(
    rf"\b(?:empec[éeè]|estoy\s+leyendo|comenc[éeè])\s+"
    rf"(?:el\s+|un\s+)?(?:libro\s+)?"
    rf"{_QUOTED_TITLE}",
    re.IGNORECASE,
)
_BOOK_DONE_RE = re.compile(
    rf"\b(?:termin[éeè]|le[íi]|acab[éeè])\s+"
    rf"(?:el\s+|un\s+)?(?:libro\s+)?"
    rf"{_QUOTED_TITLE}",
    re.IGNORECASE,
)


def _try_book_done(text: str) -> LearningIntent | None:
    m = _BOOK_DONE_RE.search(text)
    if not m:
        return None
    title = m.group("title").strip()
    if not title:
        return None
    return LearningIntent(kind="book", title=title, status="done")


def _try_book_active(text: str) -> LearningIntent | None:
    m = _BOOK_START_RE.search(text)
    if not m:
        return None
    title = m.group("title").strip()
    if not title:
        return None
    return LearningIntent(kind="book", title=title, status="active")


# ─── Courses ─────────────────────────────────────────────────────────

_COURSE_RE = re.compile(
    rf"\b(?:empec[éeè]\s+el\s+curso\s+de|estoy\s+estudiando|"
    rf"empec[éeè]\s+a\s+estudiar)\s+"
    rf"{_QUOTED_TITLE}",
    re.IGNORECASE,
)


def _try_course(text: str) -> LearningIntent | None:
    m = _COURSE_RE.search(text)
    if not m:
        return None
    title = m.group("title").strip()
    if not title:
        return None
    return LearningIntent(kind="course", title=title, status="active")


# ─── Ideas (explicit prefix) ─────────────────────────────────────────

_IDEA_RE = re.compile(
    r"^\s*(?:axi[,:\s]+)?idea\s*:\s*(?P<what>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _try_idea(text: str) -> LearningIntent | None:
    m = _IDEA_RE.match(text.strip())
    if not m:
        return None
    what = m.group("what").strip()
    if not what or len(what) > 500:
        return None
    # First clause as title, full text as body.
    title = what.split(".")[0][:200] if "." in what else what[:200]
    return LearningIntent(
        kind="idea", title=title, body=what if title != what else None,
    )


# ─── Research questions ───────────────────────────────────────────────

_RESEARCH_RE = re.compile(
    r"^\s*(?:axi[,:\s]+)?"
    r"(?:investigar|investigar\s*:)\s+(?P<what>.+?)\s*$",
    re.IGNORECASE | re.DOTALL,
)
_RESEARCH_TODO_RE = re.compile(
    r"\btengo\s+que\s+investigar\s+(?P<what>.+?)\s*\.?\s*$",
    re.IGNORECASE | re.DOTALL,
)


def _try_research(text: str) -> LearningIntent | None:
    m = _RESEARCH_RE.match(text.strip()) or _RESEARCH_TODO_RE.search(text)
    if not m:
        return None
    what = m.group("what").strip().rstrip(" .,;:")
    if not what or len(what) > 300:
        return None
    return LearningIntent(kind="research_question", title=what)


# Order: book_done before book_active (more specific verb wins).
_PARSERS = (_try_book_done, _try_book_active, _try_course,
            _try_idea, _try_research)


def parse_learning(text: str) -> LearningIntent | None:
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("learning parser %s crashed: %s", parser.__name__, e)
    return None
