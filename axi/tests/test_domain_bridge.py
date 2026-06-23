"""Tests for Slice 1: domain_bridge.py module and store.py additions.

TDD order: RED tests written first, GREEN follows after implementation.

Phases covered:
  1.1 — store.py: node_limit guard on backfill_similar_to_edges
  1.2 — store.py: upsert_domain_node_map + get_node_for_domain_entry (already exist; regression only)
  1.3 — domain_bridge.py: DomainConfig skeleton + health renderer
  1.4 — domain_bridge.py: create_fact_node_for_entry + idempotency
  1.5 — domain_bridge.py: bridge_entry (best-effort wrapper)
  1.6 — domain_bridge.py: create_fact_node_for_interaction shim
  1.7 — dashboard.py + mcp_tools.py: health call sites wired (integration)
  1.9 — same-day linker integration with health + meeting nodes
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import patch, MagicMock

import pytest


# ─── helpers ────────────────────────────────────────────────────────────────


def _insert_fact_node(conn, *, label: str = "test", domain: str = "health") -> int:
    """Insert a bare fact node directly; return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", label, "{}", domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


def _insert_embedded_node(conn, *, label: str = "test", domain: str = "health") -> int:
    """Insert a fact node with a synthetic embedding blob into nodes + vec_nodes."""
    import struct

    now = time.time()
    dim = 512
    blob = struct.pack(f"{dim}f", *([0.1] * dim))
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, "
        "embedding, embedding_model, embedding_dim) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("fact", label, "{}", domain, now, now, blob, "test", dim),
    )
    conn.commit()
    nid = cur.lastrowid
    conn.execute(
        "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
        (nid, blob),
    )
    conn.commit()
    return nid


@dataclass
class HealthEntryStub:
    """Minimal duck-typed health entry for testing renderers / bridge."""
    id: str = "he-001"
    kind: str = "vital"
    raw_utterance: str | None = None
    title: str | None = None


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.1 — store.py: node_limit guard on backfill_similar_to_edges
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_similar_to_edges_node_limit_caps_processing():
    """1.1.1 RED — node_limit=2 with 5 embedded nodes processes at most 2 nodes."""
    import axi.store as store

    conn = store._connect()

    # Insert 5 embedded nodes.
    for i in range(5):
        _insert_embedded_node(conn, label=f"node {i}", domain="health")

    call_count = {"n": 0}

    def _fake_check(nid, c, *, threshold=0.85):
        call_count["n"] += 1
        return 0

    with patch("axi.store.check_and_create_similar_to_edges", side_effect=_fake_check):
        store.backfill_similar_to_edges(node_limit=2)

    assert call_count["n"] == 2, (
        f"Expected 2 nodes processed with node_limit=2, got {call_count['n']}"
    )


def test_backfill_similar_to_edges_no_limit_processes_all():
    """1.1.3 RED — no node_limit processes all embedded nodes."""
    import axi.store as store

    conn = store._connect()

    for i in range(4):
        _insert_embedded_node(conn, label=f"all-node {i}", domain="health")

    call_count = {"n": 0}

    def _fake_check(nid, c, *, threshold=0.85):
        call_count["n"] += 1
        return 0

    with patch("axi.store.check_and_create_similar_to_edges", side_effect=_fake_check):
        store.backfill_similar_to_edges()  # no limit

    assert call_count["n"] == 4, (
        f"Expected all 4 nodes processed when no limit set, got {call_count['n']}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.3 — domain_bridge.py: health renderer
# ═══════════════════════════════════════════════════════════════════════════


def test_health_renderer_uses_raw_utterance():
    """1.3.1 RED — raw_utterance present → renderer returns it."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="slept 6h", title="ignored")
    result = _health_renderer(entry)
    assert result == "slept 6h"


def test_health_renderer_falls_back_to_title():
    """1.3.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance=None, title="poor sleep")
    result = _health_renderer(entry)
    assert result == "poor sleep"


def test_health_renderer_fallback_structured():
    """1.3.1 RED — neither raw_utterance nor title → returns non-empty structured string."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance=None, title=None, kind="vital")
    result = _health_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    assert "health" in result.lower() or "vital" in result.lower()


def test_health_renderer_truncates_to_120():
    """1.3.1 triangulation — raw_utterance > 120 chars is truncated."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="x" * 200)
    result = _health_renderer(entry)
    assert len(result) <= 120


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.4 — domain_bridge.py: create_fact_node_for_entry + idempotency
# ═══════════════════════════════════════════════════════════════════════════


def test_create_fact_node_for_entry_creates_node_and_map():
    """1.4.1 RED — creates exactly one node in nodes + one row in domain_node_map."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = HealthEntryStub(id="he-create-001", raw_utterance="presión 114/83, pulso 55")

    nid = create_fact_node_for_entry("health", entry)

    conn = store._connect()

    node = conn.execute("SELECT * FROM nodes WHERE id = ?", (nid,)).fetchone()
    assert node is not None, "Node not found in nodes table"
    assert node["kind"] == "fact"
    assert node["domain"] == "health"
    assert "presión" in node["label"]

    map_row = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()
    assert map_row is not None, "domain_node_map row not found"
    assert int(map_row["node_id"]) == nid


def test_create_fact_node_for_entry_idempotent():
    """1.4.1 RED — second call returns same node_id, no new rows."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = HealthEntryStub(id="he-idem-001", raw_utterance="glucosa 110 mg/dL")

    nid1 = create_fact_node_for_entry("health", entry)
    nid2 = create_fact_node_for_entry("health", entry)

    assert nid1 == nid2, "Second call must return same node_id"

    conn = store._connect()
    count = conn.execute(
        "SELECT COUNT(*) FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()[0]
    assert count == 1, f"Expected exactly 1 domain_node_map row, found {count}"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.5 — domain_bridge.py: bridge_entry (best-effort wrapper)
# ═══════════════════════════════════════════════════════════════════════════


def test_bridge_entry_returns_int_node_id():
    """1.5.1 RED — bridge_entry returns an int."""
    from axi.domain_bridge import bridge_entry

    entry = HealthEntryStub(id="he-bridge-001", raw_utterance="presión 120/80")
    result = bridge_entry("health", entry)
    assert isinstance(result, int)
    assert result > 0


def test_bridge_entry_swallows_exceptions():
    """1.5.1 RED — exception during create → returns None, no propagation."""
    from axi.domain_bridge import bridge_entry

    # Entry with no .id attribute will cause an error in the inner call.
    class BadEntry:
        raw_utterance = "test"
        title = "test"
        kind = "vital"
        # intentionally no .id

    result = bridge_entry("health", BadEntry())
    assert result is None, "bridge_entry must return None when an exception occurs"


def test_bridge_entry_embedding_is_null_after_create():
    """1.5.1 RED — node is created with embedding IS NULL (async embed)."""
    import axi.store as store
    from axi.domain_bridge import bridge_entry

    entry = HealthEntryStub(id="he-embed-001", raw_utterance="pulso 55")
    nid = bridge_entry("health", entry)
    assert nid is not None

    conn = store._connect()
    row = conn.execute("SELECT embedding FROM nodes WHERE id = ?", (nid,)).fetchone()
    assert row is not None
    # Embedding is async — immediately after create it must be NULL.
    assert row[0] is None, "Embedding should be NULL immediately after bridge_entry (async)"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.6 — domain_bridge.py: create_fact_node_for_interaction shim
# ═══════════════════════════════════════════════════════════════════════════


def test_create_fact_node_for_interaction_shim():
    """1.6.1 RED — shim calls through to create_fact_node_for_entry('relationships', ...)."""
    from axi.domain_bridge import create_fact_node_for_interaction, create_fact_node_for_entry

    @dataclass
    class InteractionStub:
        id: str = "rel-001"
        raw_utterance: str | None = "Met with Alice"
        title: str | None = None
        kind: str = "note"

    stub = InteractionStub()

    with patch("axi.domain_bridge.create_fact_node_for_entry", return_value=42) as mock_fn:
        result = create_fact_node_for_interaction(stub)

    mock_fn.assert_called_once_with("relationships", stub)
    assert result == 42


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.9 — same-day linker integration with health + meeting nodes
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.7 — Health API call site wiring integration test
# ═══════════════════════════════════════════════════════════════════════════


def test_health_api_post_creates_domain_node_map_row(monkeypatch):
    """1.7.1 RED — POST /api/health/entries results in a domain_node_map row."""
    import axi.store as store
    from fastapi.testclient import TestClient

    # Isolate health DB.
    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "health.db")
        key_path = os.path.join(td, "health.key")
        monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", key_path)
        from lifeos.health import store as hs
        hs.apply_migrations()

        from axi import dashboard
        monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
        monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
        monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
        monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
            "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
        })
        monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
            "used": 100, "total": 1000, "pct": 10.0,
        })
        monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

        client = TestClient(dashboard.app)
        from datetime import datetime, timezone
        now_iso = datetime.now(timezone.utc).isoformat()
        resp = client.post(
            "/api/health/entries",
            json={"kind": "vital", "title": "presión 114/83, pulso 55", "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='health'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for health after POST, got {len(rows)}"
        )


def test_same_day_linker_connects_health_and_meeting_nodes():
    """1.9.1 RED — health fact node and meeting fact node on same day get linked."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()
    conn.row_factory = store._connect().__class__.__mro__  # ensure Row factory

    # Re-open with proper row factory.
    import sqlcipher3
    store._connect().row_factory = sqlcipher3.Row

    c = store._connect()
    c.row_factory = sqlcipher3.Row

    # Insert a health fact node for "today" (recent).
    now = time.time()
    health_nid = _insert_fact_node(c, label="slept 6h - poor quality", domain="health")
    # Insert a meeting fact node for the same day.
    meeting_nid = _insert_fact_node(c, label="team standup", domain="meetings")

    # Run the same-day linker (window covers today).
    edges_created = run_same_day_linker(c, window_days=1)

    # Check there is an edge between the two nodes.
    edge = c.execute(
        "SELECT 1 FROM edges WHERE "
        "((from_id=? AND to_id=?) OR (from_id=? AND to_id=?)) "
        "AND kind='same-day'",
        (health_nid, meeting_nid, meeting_nid, health_nid),
    ).fetchone()
    assert edge is not None, (
        "Expected a same-day edge between health node and meeting node; "
        f"edges_created={edges_created}"
    )
