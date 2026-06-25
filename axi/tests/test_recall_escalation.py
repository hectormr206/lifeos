"""Tests for recall escalation feature.

Covers:
  1-5:   looks_like_personal_recall — True cases
  6-10:  looks_like_personal_recall — False cases
  11:    build_recall_block escalation fires for personal query
  12:    build_recall_block escalation blocked for casual query
  13:    build_recall_block no escalation when escalate_distance=None
  14:    NO double embed: semantic_search_nodes called exactly once even when escalation fires
  15:    brain._build_messages no escalation when flag off
  16:    brain._build_messages escalation injects recall for personal query
"""
from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# 1–5. looks_like_personal_recall — True cases
# ---------------------------------------------------------------------------

def test_looks_like_personal_recall_true_presion_dormi():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("¿qué presión tenía cuando dormí mal?") is True


def test_looks_like_personal_recall_true_pulso_dormi():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("¿cómo estaba mi pulso los días que dormí poco?") is True


def test_looks_like_personal_recall_true_cuanto_dormi():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("¿cuánto dormí la noche de la presión más alta?") is True


def test_looks_like_personal_recall_true_pesaba():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("cuánto pesaba el mes pasado") is True


def test_looks_like_personal_recall_true_gasolina():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("qué gasté en gasolina") is True


# ---------------------------------------------------------------------------
# 6–10. looks_like_personal_recall — False cases
# ---------------------------------------------------------------------------

def test_looks_like_personal_recall_false_greeting():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("hola Axi cómo estás") is False


def test_looks_like_personal_recall_false_joke():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("contame un chiste") is False


def test_looks_like_personal_recall_false_thanks():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("gracias sos un genio") is False


def test_looks_like_personal_recall_false_time():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("qué hora es") is False


def test_looks_like_personal_recall_false_react():
    from axi.recall import looks_like_personal_recall
    assert looks_like_personal_recall("cómo funciona React") is False


# ---------------------------------------------------------------------------
# Helpers for build_recall_block tests
# ---------------------------------------------------------------------------

def _make_node(distance: float, label: str = "test fact", occurred_at: float = 1_700_000_000.0):
    return {
        "id": 1,
        "label": label,
        "distance": distance,
        "occurred_at": occurred_at,
        "created_at": occurred_at,
    }


def _make_neighbor(label: str, occurred_at: float = 1_700_000_000.0):
    return {
        "id": 2,
        "label": label,
        "occurred_at": occurred_at,
        "created_at": occurred_at,
    }


# ---------------------------------------------------------------------------
# 11. build_recall_block escalation fires for personal query
# ---------------------------------------------------------------------------

def test_build_recall_block_escalation_fires_for_personal_query(monkeypatch):
    """Nodes at distance 0.85 (above 0.78, below 0.9) + personal query + escalate_distance=0.9
    → result is non-empty (escalation fires)."""
    from axi import store, config
    import axi.recall as recall_mod

    node = _make_node(distance=0.85, label="presión 120/80")
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    result = recall_mod.build_recall_block(
        "¿qué presión tenía cuando dormí mal?",
        max_distance=0.78,
        escalate_distance=0.9,
    )
    assert result != "", "Expected non-empty recall block when escalation fires for personal query"


# ---------------------------------------------------------------------------
# 12. build_recall_block escalation blocked for casual query
# ---------------------------------------------------------------------------

def test_build_recall_block_escalation_blocked_for_casual_query(monkeypatch):
    """Nodes at distance 0.85, casual query, escalate_distance=0.9 → result is '' (blocked)."""
    from axi import store, config
    import axi.recall as recall_mod

    node = _make_node(distance=0.85, label="presión 120/80")
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    result = recall_mod.build_recall_block(
        "hola",
        max_distance=0.78,
        escalate_distance=0.9,
    )
    assert result == "", "Expected empty recall block when casual query and escalation should be blocked"


# ---------------------------------------------------------------------------
# 13. escalate_distance=None → no escalation (behavior identical to current)
# ---------------------------------------------------------------------------

def test_build_recall_block_no_escalation_when_escalate_distance_none(monkeypatch):
    """Nodes at distance 0.85, personal query, escalate_distance=None → result is ''."""
    from axi import store, config
    import axi.recall as recall_mod

    node = _make_node(distance=0.85, label="presión 120/80")
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    result = recall_mod.build_recall_block(
        "¿qué presión tenía cuando dormí mal?",
        max_distance=0.78,
        escalate_distance=None,
    )
    assert result == "", "Expected empty recall block when escalate_distance=None (no escalation)"


# ---------------------------------------------------------------------------
# 14. NO double embed: semantic_search_nodes called exactly once
# ---------------------------------------------------------------------------

def test_build_recall_block_escalation_no_double_embed(monkeypatch):
    """semantic_search_nodes is called exactly once even when escalation path fires."""
    from axi import store, config
    import axi.recall as recall_mod

    call_count = 0
    node = _make_node(distance=0.85, label="presión 120/80")

    def counting_search(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return [node]

    monkeypatch.setattr(store, "semantic_search_nodes", counting_search)
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    recall_mod.build_recall_block(
        "¿qué presión tenía cuando dormí mal?",
        max_distance=0.78,
        escalate_distance=0.9,
    )
    assert call_count == 1, f"Expected exactly 1 embed call, got {call_count}"


# ---------------------------------------------------------------------------
# 15. Config flag off → brain passes escalate_distance=None → no escalation
# ---------------------------------------------------------------------------

def test_brain_build_messages_no_escalation_when_flag_off(monkeypatch):
    """When recall_escalation_enabled=False, brain passes escalate_distance=None."""
    from axi import config, brain
    import axi.recall as recall_mod

    captured_kwargs: dict = {}

    def spy_build_recall_block(query, **kwargs):
        captured_kwargs.update(kwargs)
        return ""

    _orig_config_get = config.get

    def _mock_config_get(key, default=None):
        if key == "graph_recall":
            return True
        if key == "recall_escalation_enabled":
            return False
        if key == "graph_recall_max_distance":
            return 0.78
        if key == "graph_recall_tool_max_distance":
            return 0.9
        return _orig_config_get(key, default)

    monkeypatch.setattr(config, "get", _mock_config_get)
    monkeypatch.setattr(recall_mod, "build_recall_block", spy_build_recall_block)

    brain._build_messages("¿qué presión tenía cuando dormí mal?", "eres Axi")

    assert captured_kwargs.get("escalate_distance") is None, (
        f"Expected escalate_distance=None when flag is off, got {captured_kwargs.get('escalate_distance')}"
    )


# ---------------------------------------------------------------------------
# 16. Flag on + personal query + nodes at 0.85 → recall injected in _build_messages
# ---------------------------------------------------------------------------

def test_brain_build_messages_escalation_injects_recall_for_personal_query(monkeypatch):
    """Flag on + personal compound query + nodes at 0.85 → recall block IS injected."""
    from axi import config, brain, store
    import axi.recall as recall_mod

    node = _make_node(distance=0.85, label="presión 120/80")

    _orig_config_get = config.get

    def _mock_config_get(key, default=None):
        if key == "graph_recall":
            return True
        if key == "recall_escalation_enabled":
            return True
        if key == "graph_recall_max_distance":
            return 0.78
        if key == "graph_recall_tool_max_distance":
            return 0.9
        if key == "timezone":
            return "UTC"
        return _orig_config_get(key, default)

    monkeypatch.setattr(config, "get", _mock_config_get)
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])

    msgs = brain._build_messages(
        "¿qué presión tenía cuando dormí mal?",
        "eres Axi",
    )

    system_content = msgs[0]["content"]
    assert "presión 120/80" in system_content or "MEMORIA RELEVANTE" in system_content, (
        "Expected recall block injected in system content when flag is on and escalation fires"
    )


# ---------------------------------------------------------------------------
# 17. Heuristic false positive WITHOUT a near node → still no escalation.
#     Proves the 0.9 distance backstop — not the heuristic — is the real gate.
# ---------------------------------------------------------------------------

def test_build_recall_block_false_positive_heuristic_does_not_leak(monkeypatch):
    """A heuristic false positive ('peso' in a non-health question) must NOT leak
    facts when no node sits within escalate_distance. The 0.9 backstop is the gate."""
    from axi import store, config
    import axi.recall as recall_mod

    # "peso" trips the heuristic, but this is not a health question.
    assert recall_mod.looks_like_personal_recall("cuánto cuesta un peso mexicano") is True

    # Only far nodes exist — nothing within 0.9.
    far_node = _make_node(distance=0.95, label="presión 120/80")
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [far_node])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    result = recall_mod.build_recall_block(
        "cuánto cuesta un peso mexicano",
        max_distance=0.78,
        escalate_distance=0.9,
    )
    assert result == "", "False-positive heuristic must not leak when no node is within 0.9"


# ---------------------------------------------------------------------------
# 18. Escalation is SKIPPED when the tight filter already has matches —
#     junk within the wide gate must not be dragged in.
# ---------------------------------------------------------------------------

def test_build_recall_block_no_escalation_when_tight_filter_nonempty(monkeypatch):
    """When a node passes the tight 0.78 gate, escalation never runs, so a second
    node at 0.88 (inside 0.9 but outside 0.78) must NOT be included."""
    from axi import store, config
    import axi.recall as recall_mod

    tight = {"id": 1, "label": "dormí 4.9h", "distance": 0.70,
             "occurred_at": 1_700_000_000.0, "created_at": 1_700_000_000.0}
    wide_junk = {"id": 2, "label": "JUNK-0-88", "distance": 0.88,
                 "occurred_at": 1_700_000_000.0, "created_at": 1_700_000_000.0}
    monkeypatch.setattr(store, "semantic_search_nodes", lambda *a, **kw: [tight, wide_junk])
    monkeypatch.setattr(store, "same_day_neighbors", lambda *a, **kw: [])
    monkeypatch.setattr(config, "get", lambda key, default=None: {
        "timezone": "UTC",
    }.get(key, default))

    result = recall_mod.build_recall_block(
        "¿qué presión tenía cuando dormí mal?",
        max_distance=0.78,
        escalate_distance=0.9,
    )
    assert "dormí 4.9h" in result, "Tight match must be present"
    assert "JUNK-0-88" not in result, "Escalation must be skipped when tight filter is non-empty"
