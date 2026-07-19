"""Subject-attribution filtering for graph recall.

Health/exercise family readings are stored as fact nodes carrying
data={"subject": "<relation>"} (e.g. "esposa"). The user's OWN readings carry
no subject. build_recall_block must, by default, surface ONLY the user's own
facts so generic health recall ("tu presión", digests, trends) never mixes in
a family member's readings. Family facts are opt-in: surfaced only when the
query explicitly names the family member ("la presión de mi esposa") or when
the caller passes subject="all" / subject="<relation>".
"""
from __future__ import annotations

import time

from axi import config
from axi import recall as _recall
from axi import store as _store

_SELF_LABEL = "presión 118/74, pulso 61"
_WIFE_LABEL = "presión 121/79, pulso 61"


def _fact(nid: int, label: str, subject: str | None = None, dist: float = 0.1) -> dict:
    data = {"subject": subject} if subject else {}
    now = time.time()
    return {
        "id": nid, "kind": "fact", "label": label, "domain": "health",
        "occurred_at": now, "created_at": now, "distance": dist, "data": data,
    }


def _patch(monkeypatch, nodes: list[dict]) -> None:
    monkeypatch.setattr(
        config, "get",
        lambda key, default=None: "UTC" if key == "timezone" else default,
    )
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: list(nodes))
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])
    monkeypatch.setattr(_store, "recent_facts", lambda *a, **kw: [])
    monkeypatch.setattr(_store, "search_nodes_fts", lambda *a, **kw: [])


def test_default_recall_excludes_family_subject(monkeypatch) -> None:
    """Generic health query → only the user's own facts (self)."""
    _patch(monkeypatch, [_fact(1, _SELF_LABEL), _fact(2, _WIFE_LABEL, subject="esposa")])
    block = _recall.build_recall_block("¿cómo va mi presión?")
    assert _SELF_LABEL in block
    assert _WIFE_LABEL not in block


def test_subject_all_includes_family(monkeypatch) -> None:
    """subject='all' surfaces both the user's and the family member's facts."""
    _patch(monkeypatch, [_fact(1, _SELF_LABEL), _fact(2, _WIFE_LABEL, subject="esposa")])
    block = _recall.build_recall_block("presión", subject="all")
    assert _SELF_LABEL in block
    assert _WIFE_LABEL in block


def test_explicit_family_subject_returns_only_that_person(monkeypatch) -> None:
    """subject='esposa' surfaces only the wife's facts, not the user's own."""
    _patch(monkeypatch, [_fact(1, _SELF_LABEL), _fact(2, _WIFE_LABEL, subject="esposa")])
    block = _recall.build_recall_block("presión", subject="esposa")
    assert _WIFE_LABEL in block
    assert _SELF_LABEL not in block


def test_query_naming_family_member_opts_in_automatically(monkeypatch) -> None:
    """A query explicitly about a family member ('de mi esposa') auto-surfaces
    that member's facts (family opt-in via the query itself)."""
    _patch(monkeypatch, [_fact(1, _SELF_LABEL), _fact(2, _WIFE_LABEL, subject="esposa")])
    block = _recall.build_recall_block("¿cómo está la presión de mi esposa?")
    assert _WIFE_LABEL in block
    assert _SELF_LABEL not in block


def test_mid_sentence_family_query_does_not_leak_self(monkeypatch) -> None:
    """Regression: 'mi esposa' mid-sentence (not at a marker boundary) must
    resolve to the wife, NOT silently default to the user's own readings."""
    _patch(monkeypatch, [_fact(1, _SELF_LABEL), _fact(2, _WIFE_LABEL, subject="esposa")])
    block = _recall.build_recall_block("¿cómo estaba mi esposa ayer?")
    assert _WIFE_LABEL in block
    assert _SELF_LABEL not in block
