"""Tests for store.py Layer-3 graph-recall additions.

Tests cover:
  - knn_nodes_scored: alias for knn_nodes_with_distance
  - semantic_search_nodes: includes occurred_at, distance, and timeout param
  - same_day_neighbors: bidirectional, self-exclusion, empty, error cases
"""
from __future__ import annotations

import time

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _insert_node(conn, label: str, *, occurred_at: float | None = None) -> int:
    """Insert a minimal node through the production writer and return its id.

    Goes through `store.add_node` rather than a raw INSERT so the row carries
    a `uuid`: from PR6a on, edges resolve through their endpoints' uuids, and a
    uuid-less node is invisible to every edge read. See the same note in
    test_linkers.py.
    """
    from axi import store as _store

    node_id = _store.add_node(kind="fact", label=label, domain="health")
    if occurred_at is not None:
        conn.execute("UPDATE nodes SET occurred_at=? WHERE id=?", (occurred_at, node_id))
    conn.commit()
    return node_id


def _insert_vec(conn, node_id: int, vector: list[float]) -> None:
    """Insert an embedding into vec_nodes for testing KNN."""
    import struct
    from axi.store import _load_sqlite_vec
    _load_sqlite_vec(conn)
    vec = vector[:512]
    blob = struct.pack(f"{len(vec)}f", *vec)
    conn.execute(
        "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
        (node_id, blob),
    )
    conn.commit()


def _make_vec(dim: int = 512, value: float = 0.1) -> list[float]:
    """Return a simple unit-ish vector for testing (512 dims required by vec_nodes)."""
    return [value] * dim


# ---------------------------------------------------------------------------
# 1. knn_nodes_scored returns sorted (id, distance) tuples
# ---------------------------------------------------------------------------

def test_knn_nodes_scored_returns_sorted_id_distance_tuples():
    """knn_nodes_scored must return a list of (node_id, float) sorted by distance."""
    from axi import store
    from axi.store import knn_nodes_scored

    conn = store._connect()

    # Insert two nodes with different vectors so we get two distinct distances.
    node1 = _insert_node(conn, "node-close")
    node2 = _insert_node(conn, "node-far")

    query_vec = _make_vec(512, 1.0)
    close_vec = _make_vec(512, 0.99)   # nearly identical to query → smallest distance
    far_vec = _make_vec(512, 0.1)      # different direction → larger distance

    _insert_vec(conn, node1, close_vec)
    _insert_vec(conn, node2, far_vec)

    results = knn_nodes_scored(conn, vector=query_vec, k=2)

    assert len(results) == 2
    # Each item is a (int, float) tuple
    for item in results:
        assert isinstance(item, tuple) and len(item) == 2
        assert isinstance(item[0], int)
        assert isinstance(item[1], float)

    # Results are sorted by ascending distance (closest first)
    assert results[0][1] <= results[1][1]
    # The closest node is node1
    assert results[0][0] == node1


# ---------------------------------------------------------------------------
# 2. semantic_search_nodes includes occurred_at and distance
# ---------------------------------------------------------------------------

def test_semantic_search_nodes_includes_occurred_at_and_distance(monkeypatch):
    """Each dict returned by semantic_search_nodes must include occurred_at and distance."""
    from axi import store

    conn = store._connect()
    occurred = time.time() - 3600.0  # 1 hour ago

    node_id = _insert_node(conn, "health-fact", occurred_at=occurred)
    vec = _make_vec(512, 0.8)
    _insert_vec(conn, node_id, vec)

    # Patch embed_text so we don't need a real embed service.
    monkeypatch.setattr(store, "embed_text", lambda *a, **kw: _make_vec(512, 0.8))

    results = store.semantic_search_nodes("health", k=5, conn=conn)

    assert len(results) >= 1
    row = results[0]
    # Must have occurred_at (may be float or None) and distance (float)
    assert "occurred_at" in row
    assert "distance" in row
    assert isinstance(row["distance"], float)
    # The occurred_at we set should come back
    assert abs(row["occurred_at"] - occurred) < 1.0


# ---------------------------------------------------------------------------
# 3. semantic_search_nodes preserves KNN ordering
# ---------------------------------------------------------------------------

def test_semantic_search_nodes_preserves_knn_ordering(monkeypatch):
    """semantic_search_nodes must return rows in KNN distance order (closest first)."""
    from axi import store

    conn = store._connect()

    node_close = _insert_node(conn, "close-node")
    node_far = _insert_node(conn, "far-node")

    query_vec = _make_vec(512, 1.0)
    _insert_vec(conn, node_close, _make_vec(512, 0.99))
    _insert_vec(conn, node_far, _make_vec(512, 0.1))

    monkeypatch.setattr(store, "embed_text", lambda *a, **kw: query_vec)

    results = store.semantic_search_nodes("anything", k=5, conn=conn)

    ids = [r["id"] for r in results]
    assert ids.index(node_close) < ids.index(node_far)

    # Distances are non-decreasing
    distances = [r["distance"] for r in results]
    assert all(distances[i] <= distances[i + 1] for i in range(len(distances) - 1))


# ---------------------------------------------------------------------------
# 4. semantic_search_nodes returns [] when embed is down
# ---------------------------------------------------------------------------

def test_semantic_search_nodes_returns_empty_when_embed_down(monkeypatch):
    """semantic_search_nodes must return [] and not raise when embed service is down."""
    from axi import store
    from axi.embed_client import EmbedServiceError

    def _raise(*a, **kw):
        raise EmbedServiceError("service down")

    monkeypatch.setattr(store, "embed_text", _raise)

    result = store.semantic_search_nodes("anything")
    assert result == []


# ---------------------------------------------------------------------------
# 5. semantic_search_nodes passes timeout to embed_text
# ---------------------------------------------------------------------------

def test_semantic_search_nodes_passes_timeout_to_embed_text(monkeypatch):
    """semantic_search_nodes must forward the timeout kwarg to embed_text."""
    from axi import store

    captured: list = []

    def _stub_embed(text, *, mode="passage", timeout=None):
        captured.append(timeout)
        raise store.embed_text.__class__  # just return [] path via exception

    # Patch embed_text to capture the timeout and then raise so we get []
    from axi.embed_client import EmbedServiceError

    def _capture_embed(text, *, mode="passage", timeout=None):
        captured.append(timeout)
        raise EmbedServiceError("stub")

    monkeypatch.setattr(store, "embed_text", _capture_embed)

    result = store.semantic_search_nodes("test", timeout=1.5)
    assert result == []
    assert len(captured) == 1
    assert captured[0] == 1.5


# ---------------------------------------------------------------------------
# FIX 5 — same_day_neighbors: bidirectional, self-exclusion, empty, error
# ---------------------------------------------------------------------------

def _insert_same_day_edge(conn, from_id: int, to_id: int) -> None:
    """Insert a same-day edge between two nodes through the production writer.

    Goes through `store.add_edge` rather than a raw INSERT so the row carries
    `src_uuid`/`dst_uuid`. Every production edge-insert path dual-writes them,
    and from PR6a on the readers resolve edges through those columns — a raw
    INSERT that omits them produces an edge no read can see.
    """
    from axi import store as _store

    _store.add_edge(from_id, to_id, "same-day")
    conn.commit()


def test_same_day_neighbors_forward_direction():
    """Edge A→B returns B from A's perspective."""
    from axi import store

    conn = store._connect()
    node_a = _insert_node(conn, "node-A")
    node_b = _insert_node(conn, "node-B")
    _insert_same_day_edge(conn, node_a, node_b)

    result = store.same_day_neighbors(node_a, conn=conn)
    ids = [r["id"] for r in result]
    assert node_b in ids


def test_same_day_neighbors_reverse_direction():
    """Edge A→B returns A from B's perspective (reverse lookup)."""
    from axi import store

    conn = store._connect()
    node_a = _insert_node(conn, "rev-A")
    node_b = _insert_node(conn, "rev-B")
    _insert_same_day_edge(conn, node_a, node_b)

    result = store.same_day_neighbors(node_b, conn=conn)
    ids = [r["id"] for r in result]
    assert node_a in ids


def test_same_day_neighbors_self_exclusion():
    """Self (node_id == n.id) must never appear in results."""
    from axi import store

    conn = store._connect()
    node_x = _insert_node(conn, "self-exclude-X")
    node_y = _insert_node(conn, "self-exclude-Y")
    _insert_same_day_edge(conn, node_x, node_y)

    result = store.same_day_neighbors(node_x, conn=conn)
    ids = [r["id"] for r in result]
    assert node_x not in ids


def test_same_day_neighbors_empty_graph():
    """Returns [] when there are no same-day edges for the node."""
    from axi import store

    conn = store._connect()
    isolated_node = _insert_node(conn, "isolated")

    result = store.same_day_neighbors(isolated_node, conn=conn)
    assert result == []


def test_same_day_neighbors_store_error_swallowed():
    """Returns [] and does not raise when the DB connection errors."""
    from axi import store

    class _BadConn:
        def execute(self, *a, **kw):
            raise RuntimeError("simulated DB failure")

    result = store.same_day_neighbors(999, conn=_BadConn())
    assert result == []
