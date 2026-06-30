"""Tests for axi.recall.build_recall_block (Layer 3 — graph recall)."""
from __future__ import annotations

import time

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _node_dict(
    node_id: int,
    label: str,
    *,
    distance: float = 0.3,
    occurred_at: float | None = None,
    created_at: float | None = None,
) -> dict:
    return {
        "id": node_id,
        "kind": "fact",
        "label": label,
        "domain": "health",
        "distance": distance,
        "occurred_at": occurred_at,
        "created_at": created_at or time.time(),
    }


# ---------------------------------------------------------------------------
# 1. Empty when no nodes returned by semantic_search_nodes
# ---------------------------------------------------------------------------

def test_build_recall_block_empty_when_no_nodes(monkeypatch):
    """Returns '' when semantic_search_nodes returns no results."""
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])

    from axi.recall import build_recall_block
    result = build_recall_block("cualquier cosa")
    assert result == ""


# ---------------------------------------------------------------------------
# 2. Empty when all nodes are above the distance threshold
# ---------------------------------------------------------------------------

def test_build_recall_block_empty_when_all_above_threshold(monkeypatch):
    """Returns '' when every node's distance exceeds max_distance."""
    import axi.store as _store

    far_node = _node_dict(1, "distant fact", distance=0.99)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [far_node])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6)
    assert result == ""


# ---------------------------------------------------------------------------
# 3. Empty when embed service is down (semantic_search_nodes returns [])
# ---------------------------------------------------------------------------

def test_build_recall_block_empty_when_embed_down(monkeypatch):
    """Returns '' (never raises) when semantic_search_nodes returns [] due to embed down."""
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query")
    assert result == ""


# ---------------------------------------------------------------------------
# 4. Pulls same-day neighbor into same day line
# ---------------------------------------------------------------------------

def test_build_recall_block_pulls_same_day_neighbor(monkeypatch):
    """A matched node's same-day neighbor should appear in the SAME day's output line."""
    import axi.store as _store

    # Use a fixed timestamp: 2026-06-11 noon UTC (will be the same day in any tz close to UTC)
    day_ts = 1749643200.0  # 2026-06-11 00:00:00 UTC

    main_node = _node_dict(10, "dormí 4.9h", distance=0.2, occurred_at=day_ts + 3600)
    neighbor_node = _node_dict(20, "presión 115/81", distance=None, occurred_at=day_ts + 7200)

    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [main_node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [neighbor_node])

    from axi.recall import build_recall_block
    result = build_recall_block("cómo dormí?", max_distance=0.6)

    # Both labels should appear in the block
    assert "dormí 4.9h" in result
    assert "presión 115/81" in result
    # They should be on the SAME day line (only one bullet/line for that date)
    lines_with_content = [ln for ln in result.splitlines() if "dormí 4.9h" in ln or "presión 115/81" in ln]
    # Both labels should be on the same line
    assert any("dormí 4.9h" in ln and "presión 115/81" in ln for ln in lines_with_content)


# ---------------------------------------------------------------------------
# 5. Date rendered in config timezone
# ---------------------------------------------------------------------------

def test_build_recall_block_date_in_config_tz(monkeypatch):
    """The day grouping uses the config timezone, not UTC."""
    import axi.store as _store
    from axi import config

    # Force timezone to America/Mexico_City (UTC-6) via monkeypatch
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        "America/Mexico_City" if key == "timezone" else default
    ))

    # 2026-06-11 02:00 UTC == 2026-06-10 20:00 in Mexico_City
    # So this should be grouped under 2026-06-10 in Mexico_City tz
    ts = 1749600000.0 + 7200  # approx 2026-06-11 02:00 UTC

    node = _node_dict(5, "hecho nocturno", distance=0.2, occurred_at=ts)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6)

    assert result != ""
    # The date line should exist and include the node's label
    assert "hecho nocturno" in result


# ---------------------------------------------------------------------------
# 6. Spanish header and month names
# ---------------------------------------------------------------------------

def test_build_recall_block_spanish_header_and_months(monkeypatch):
    """Default (no lang / es lang) uses Spanish header and month names."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: (
        "UTC" if key == "timezone" else default
    ))

    # 2026-06-11 noon UTC
    ts = 1749643200.0 + 43200

    node = _node_dict(1, "hecho salud", distance=0.2, occurred_at=ts)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", lang=None, max_distance=0.6)

    assert "MEMORIA RELEVANTE" in result
    assert "junio" in result  # Spanish month name for June


# ---------------------------------------------------------------------------
# 7. English header and month names
# ---------------------------------------------------------------------------

def test_build_recall_block_english_header_and_months(monkeypatch):
    """lang='en' uses English header and English month names."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: (
        "UTC" if key == "timezone" else default
    ))

    # 2026-06-11 noon UTC
    ts = 1749643200.0 + 43200

    node = _node_dict(1, "slept 7h", distance=0.2, occurred_at=ts)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", lang="en", max_distance=0.6)

    assert "RELEVANT MEMORY" in result
    assert "June" in result


# ---------------------------------------------------------------------------
# 8. max_facts cap respected
# ---------------------------------------------------------------------------

def test_build_recall_block_max_facts_cap(monkeypatch):
    """Only max_facts most-recent days are included in the output."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: (
        "UTC" if key == "timezone" else default
    ))

    # Create 10 nodes each one day apart
    base_ts = 1749643200.0  # 2026-06-11
    nodes = [
        _node_dict(i + 1, f"fact-day-{i}", distance=0.2, occurred_at=base_ts - i * 86400)
        for i in range(10)
    ]
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: nodes)
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_days=3, max_distance=0.6)

    # Count bullet lines (lines starting with "- ")
    bullet_lines = [ln for ln in result.splitlines() if ln.strip().startswith("- ")]
    # Header line is not a bullet, date lines are bullets: at most max_facts=3
    assert len(bullet_lines) <= 3


# ---------------------------------------------------------------------------
# 9. Never raises when store raises
# ---------------------------------------------------------------------------

def test_build_recall_block_never_raises_when_store_raises(monkeypatch):
    """Returns '' without raising when semantic_search_nodes raises."""
    import axi.store as _store

    def _raise(*a, **kw):
        raise RuntimeError("unexpected store error")

    monkeypatch.setattr(_store, "semantic_search_nodes", _raise)

    from axi.recall import build_recall_block
    result = build_recall_block("query")
    assert result == ""


# ---------------------------------------------------------------------------
# FIX 2 — per-day label cap and total-fact cap
# ---------------------------------------------------------------------------

def test_build_recall_block_per_day_label_cap(monkeypatch):
    """max_labels_per_day caps labels even when a single day has many facts."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    # Single day, many neighbors (30 total)
    day_ts = 1749643200.0  # 2026-06-11 00:00:00 UTC
    main_node = _node_dict(1, "fact-main", distance=0.2, occurred_at=day_ts + 3600)
    neighbors = [
        _node_dict(i + 2, f"neighbor-{i}", distance=None, occurred_at=day_ts + i * 60)
        for i in range(29)
    ]

    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [main_node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: neighbors)

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6, max_labels_per_day=4)

    # Count labels on the single bullet line (semicolon-separated)
    bullet_lines = [ln for ln in result.splitlines() if ln.strip().startswith("- ")]
    assert len(bullet_lines) == 1
    # Labels on that line should be at most max_labels_per_day=4
    label_count = len(bullet_lines[0].split(";"))
    assert label_count <= 4


def test_build_recall_block_total_fact_cap(monkeypatch):
    """max_total_facts caps the total labels across all days."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    # 5 days, 6 nodes each day → 30 potential labels total
    base_ts = 1749643200.0  # 2026-06-11
    all_nodes = []
    for day_i in range(5):
        day_ts = base_ts - day_i * 86400
        for fact_i in range(6):
            nid = day_i * 6 + fact_i + 1
            all_nodes.append(_node_dict(nid, f"d{day_i}-f{fact_i}", distance=0.2, occurred_at=day_ts + fact_i))

    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: all_nodes)
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6, max_total_facts=8, max_labels_per_day=6)

    # Count total labels: each bullet line is "; "-joined
    bullet_lines = [ln for ln in result.splitlines() if ln.strip().startswith("- ")]
    total = sum(len(ln.split(";")) for ln in bullet_lines)
    assert total <= 8


# ---------------------------------------------------------------------------
# FIX 4 — default max_distance is 0.78 (empirically tuned for Qwen3-Embedding-4B);
# config override respected
# ---------------------------------------------------------------------------

def test_build_recall_block_default_max_distance_excludes_casual(monkeypatch):
    """A casual-chat node (distance 0.85) is excluded with the default 0.78.

    Measured against real data: casual greetings sit at 0.83+, so the default
    threshold must keep them out of the recall block.
    """
    import axi.store as _store

    node = _node_dict(1, "tangential fact", distance=0.85)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("hola Axi")  # uses default max_distance=0.78
    assert result == ""


def test_build_recall_block_default_max_distance_includes_natural_query(monkeypatch):
    """A natural recall match (distance 0.70) IS included with the default 0.78.

    Measured: 'cómo dormí esta semana' → 0.699; the default must let it through.
    """
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    node = _node_dict(1, "dormí 4.9h", distance=0.70, occurred_at=time.time())
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("cómo dormí esta semana")  # default max_distance=0.78
    assert "dormí 4.9h" in result


def test_build_recall_block_config_max_distance_override(monkeypatch):
    """Passing max_distance=0.6 explicitly includes a node at distance 0.5."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    node = _node_dict(1, "included fact", distance=0.5, occurred_at=time.time())
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6)
    assert "included fact" in result


# ---------------------------------------------------------------------------
# FIX 6 — within-day ordering by occurred_at desc
# ---------------------------------------------------------------------------

def test_build_recall_block_within_day_recency_order(monkeypatch):
    """Two same-day facts must appear most-recent-first in the bullet line."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    day_ts = 1749643200.0  # 2026-06-11 00:00:00 UTC
    # older fact: at +1h, newer fact: at +3h
    older_node = _node_dict(1, "older fact", distance=0.2, occurred_at=day_ts + 3600)
    newer_node = _node_dict(2, "newer fact", distance=0.2, occurred_at=day_ts + 10800)

    # Both returned as KNN hits (not neighbors) so they're both in the same day
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [older_node, newer_node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6)

    bullet_lines = [ln for ln in result.splitlines() if ln.strip().startswith("- ")]
    assert len(bullet_lines) == 1
    line = bullet_lines[0]
    assert "newer fact" in line and "older fact" in line
    # newer fact must appear BEFORE older fact in the semicolon-joined string
    assert line.index("newer fact") < line.index("older fact")


# ---------------------------------------------------------------------------
# FIX 7 — occurred_at=0.0 is not dropped (None check fix)
# ---------------------------------------------------------------------------

def test_build_recall_block_zero_occurred_at_not_dropped(monkeypatch):
    """A fact with occurred_at=0.0 (Unix epoch) should NOT be silently dropped."""
    import axi.store as _store
    from axi import config

    monkeypatch.setattr(config, "get", lambda key, default=None: "UTC" if key == "timezone" else default)

    # occurred_at = 0.0 is falsy but not None — the old `or` would drop it
    node = {
        "id": 1,
        "kind": "fact",
        "label": "epoch fact",
        "domain": None,
        "distance": 0.2,
        "occurred_at": 0.0,   # Unix epoch — must NOT be treated as missing
        "created_at": None,
    }
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", max_distance=0.6)
    assert "epoch fact" in result


# ---------------------------------------------------------------------------
# FIX 7 — locale_data constants are importable and match expected values
# ---------------------------------------------------------------------------

def test_locale_data_constants():
    """MONTHS_ES and MONTHS_EN are importable from locale_data with correct length."""
    from axi.locale_data import MONTHS_ES, MONTHS_EN
    assert len(MONTHS_ES) == 12
    assert len(MONTHS_EN) == 12
    assert MONTHS_ES[5] == "junio"
    assert MONTHS_EN[5] == "June"


# ---------------------------------------------------------------------------
# FIX 3a — embed timeout: build_recall_block returns "" when embed hangs
# ---------------------------------------------------------------------------

def test_build_recall_block_returns_empty_on_embed_timeout(monkeypatch):
    """When semantic_search_nodes raises (simulating timeout/hang), '' is returned."""
    import axi.store as _store
    from axi.embed_client import EmbedServiceError

    # Simulate the embed timing out (store returns [] when embed raises)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])

    from axi.recall import build_recall_block
    result = build_recall_block("query", timeout=0.001)
    assert result == ""


# ---------------------------------------------------------------------------
# Recency injection — personal queries surface freshly-logged facts even when
# semantic search misses a keyword-poor label ("110 81 51 pulsos" vs "presión")
# ---------------------------------------------------------------------------

def test_recency_injection_for_personal_query(monkeypatch):
    """A personal query folds in recent facts even with NO semantic match."""
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])
    recent = [{
        "id": 99, "kind": "fact", "label": "110 81 51 pulsos", "domain": "health",
        "occurred_at": time.time(), "created_at": time.time(),
    }]
    monkeypatch.setattr(_store, "recent_facts", lambda **kw: recent)

    from axi.recall import build_recall_block
    result = build_recall_block(
        "opinión sobre mi presión de hoy", lang="es-MX", escalate_distance=0.9
    )
    assert "110 81 51 pulsos" in result


def test_recency_injection_skipped_for_non_personal_query(monkeypatch):
    """A non-personal query never triggers recency injection (no noise)."""
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])
    called = {"recent": False}

    def _rf(**kw):
        called["recent"] = True
        return []

    monkeypatch.setattr(_store, "recent_facts", _rf)

    from axi.recall import build_recall_block
    result = build_recall_block("contame un chiste", lang="es-MX")
    assert result == ""
    assert called["recent"] is False


# ---------------------------------------------------------------------------
# Hybrid recall — lexical (FTS) lane catches keyword matches the vector search
# missed (e.g. "esposa" -> "Esposa: Celia ..." sitting just past the distance gate)
# ---------------------------------------------------------------------------

def test_fts_lane_surfaces_keyword_match_when_semantic_missed(monkeypatch):
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])
    monkeypatch.setattr(_store, "recent_facts", lambda **kw: [])
    fts_node = {
        "id": 5, "kind": "fact", "label": "Esposa: Celia García Mateo",
        "domain": "personal", "occurred_at": time.time(), "created_at": time.time(),
    }
    monkeypatch.setattr(_store, "search_nodes_fts", lambda q, limit=10: [fts_node])

    from axi.recall import build_recall_block
    out = build_recall_block("quién es mi esposa", lang="es-MX")
    assert "Celia García Mateo" in out


def test_fts_lane_skips_conversation_nodes(monkeypatch):
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])
    monkeypatch.setattr(_store, "recent_facts", lambda **kw: [])
    conv = {"id": 9, "kind": "conversation", "label": "hola que onda esposa",
            "domain": None, "occurred_at": time.time(), "created_at": time.time()}
    monkeypatch.setattr(_store, "search_nodes_fts", lambda q, limit=10: [conv])
    from axi.recall import build_recall_block
    out = build_recall_block("quién es mi esposa", lang="es-MX")
    assert out == ""  # raw chat node skipped -> nothing else -> empty


def test_fts_terms_keeps_content_drops_stopwords():
    from axi.recall import _fts_terms
    terms = _fts_terms("¿Quién es mi esposa y cuándo nos casamos?")
    assert "esposa" in terms and "casamos" in terms
    assert "quien" not in terms and "quién" not in terms and "mi" not in terms


def test_casual_query_no_fts_no_recall(monkeypatch):
    import axi.store as _store
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [])
    # search_nodes_fts must NOT even be needed; a casual query yields no terms.
    from axi.recall import _fts_terms, build_recall_block
    assert _fts_terms("hola cómo estás") == []
    assert build_recall_block("hola cómo estás", lang="es-MX") == ""


def test_undated_reading_grouped_under_sin_fecha_not_created_at(monkeypatch):
    """A reading with occurred_at=None must land under 'Sin fecha registrada' and
    NEVER be dated by its created_at — that fallback let the model fabricate a
    per-day timeline from undated readings (the BP-trend bug)."""
    import axi.store as _store

    # created some days ago, but NO measurement date (occurred_at=None)
    node = _node_dict(7, "presión 108/80", distance=0.2,
                      occurred_at=None, created_at=1750636800.0)
    monkeypatch.setattr(_store, "semantic_search_nodes", lambda *a, **kw: [node])
    monkeypatch.setattr(_store, "same_day_neighbors", lambda nid, conn=None: [])

    from axi.recall import build_recall_block
    result = build_recall_block("cómo está mi presión", max_distance=0.6)

    assert "presión 108/80" in result
    assert "Sin fecha de medición" in result
    # The reading must be on the 'Sin fecha' line, NOT on a dated ("El …"/"HOY") line.
    for ln in result.splitlines():
        if "presión 108/80" in ln:
            assert "Sin fecha de medición" in ln, f"undated reading was dated: {ln!r}"
