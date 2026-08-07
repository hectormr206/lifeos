"""Tests for /api/graph/full — Slice 3, tasks 3.1 (RED) / 3.2 (GREEN).

Covers:
  1. Returns merged nodes + edges including similar-to edges.
  2. When lifeos.db ATTACH fails → returns System A only with partial:true (no crash).
  3. Empty graph (no nodes) → returns empty with partial:false.
  4. Response shape: {nodes:[{id,label,kind,domain,has_embedding}], edges:[{source,target,kind,system}]}.
"""
from __future__ import annotations

import struct
import time
from unittest.mock import patch, MagicMock

import pytest
from fastapi.testclient import TestClient


def _float32_blob(values: list[float]) -> bytes:
    return struct.pack(f"{len(values)}f", *values)


def test_graph_full_returns_system_a_nodes_and_edges():
    """Task 3.1 RED: /api/graph/full returns System A nodes and edges."""
    from axi.dashboard import app
    import axi.store as store

    # Inserted through the store API on purpose: a raw INSERT leaves
    # nodes.uuid / edges.src_uuid NULL, a row shape production has been unable
    # to produce since task 5.14, and which PR6b's uuid-resolved reads treat as
    # a missing endpoint. Fixtures must model rows the daemon can actually write.
    nid1 = store.add_node("fact", "Alpha node", domain="health")
    nid2 = store.add_node("fact", "Beta node", domain="relationships")
    store.add_edge(nid1, nid2, "similar-to")

    client = TestClient(app)
    resp = client.get("/api/graph/full")

    assert resp.status_code == 200
    body = resp.json()
    assert "nodes" in body
    assert "edges" in body

    node_ids = {n["id"] for n in body["nodes"]}
    assert nid1 in node_ids
    assert nid2 in node_ids

    # Check node shape.
    for node in body["nodes"]:
        assert "id" in node
        assert "label" in node
        assert "kind" in node
        assert "domain" in node
        assert "has_embedding" in node

    # The similar-to edge should be present.
    edge_kinds = {e["kind"] for e in body["edges"]}
    assert "similar-to" in edge_kinds

    # Check edge shape.
    for edge in body["edges"]:
        assert "source" in edge
        assert "target" in edge
        assert "kind" in edge
        assert "system" in edge


def test_graph_full_has_embedding_field():
    """has_embedding is True when embedding BLOB is present, False otherwise."""
    from axi.dashboard import app
    import axi.store as store

    conn = store._connect()
    now = time.time()

    blob = _float32_blob([0.1] * 512)
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, "
        "embedding, embedding_model, embedding_dim) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("fact", "Embedded node", "{}", "health", now, now, blob, "test-model", 512),
    )
    nid = cur.lastrowid
    conn.commit()

    client = TestClient(app)
    resp = client.get("/api/graph/full")
    assert resp.status_code == 200

    body = resp.json()
    embedded = next((n for n in body["nodes"] if n["id"] == nid), None)
    assert embedded is not None
    assert embedded["has_embedding"] is True


def test_graph_full_partial_true_when_lifeos_db_unavailable():
    """Task 3.1 RED: when lifeos.db ATTACH fails → partial:true, System A only, no 500."""
    from axi.dashboard import app

    # Simulate ATTACH failure by patching the linker module.
    with patch("axi.dashboard._attach_lifeos_edges", side_effect=Exception("locked")):
        client = TestClient(app)
        resp = client.get("/api/graph/full")

    assert resp.status_code == 200
    body = resp.json()
    assert body.get("partial") is True
    assert "nodes" in body
    assert "edges" in body


def test_graph_full_empty_graph():
    """Task 3.1 RED: empty graph returns {nodes:[], edges:[], partial:false}."""
    from axi.dashboard import app
    import axi.store as store

    # The fresh_db fixture starts empty — no nodes.
    conn = store._connect()
    # Confirm no nodes exist.
    count = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    assert count == 0

    client = TestClient(app)
    resp = client.get("/api/graph/full")

    assert resp.status_code == 200
    body = resp.json()
    assert body["nodes"] == []
    assert body["edges"] == []
    assert body.get("partial") is False


def test_graph_full_similar_to_edges_included():
    """similar-to edges from System A are included with system='A'."""
    from axi.dashboard import app
    import axi.store as store

    # Store API, not raw SQL — see the note in the first test in this file.
    nid1 = store.add_node("fact", "Node A", domain="health")
    nid2 = store.add_node("fact", "Node B", domain="health")
    store.add_edge(nid1, nid2, "similar-to")

    client = TestClient(app)
    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    body = resp.json()

    similar_edges = [e for e in body["edges"] if e["kind"] == "similar-to"]
    assert len(similar_edges) >= 1
    assert all(e["system"] == "A" for e in similar_edges)
