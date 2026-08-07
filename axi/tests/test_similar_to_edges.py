"""Tests for similar-to auto-edges — Slice 2, tasks 2.5 (RED) / 2.6 (GREEN).

check_and_create_similar_to_edges(node_id, conn, threshold=0.85) must:
- After a node is embedded, find its KNN neighbors in vec_nodes.
- Create edges(kind='similar-to') for neighbors with cosine similarity >= threshold.
- NOT create edges for neighbors below threshold.
- Respect a configurable threshold (below 0.85 can create edges that wouldn't exist at 0.85).
- Be idempotent — duplicate edges are NOT inserted.
- NOT self-link (no edge from node to itself).

Strategy: seed vec_nodes with known close/far vectors and mock knn_nodes to control
cosine distances precisely (vec0 returns L2/cosine distances; we mock knn to return
pre-computed lists so tests are deterministic).
"""
from __future__ import annotations

import struct
import time
import uuid as _uuid
from unittest.mock import patch, MagicMock

import pytest


def _float32_blob(values: list[float]) -> bytes:
    return struct.pack(f"{len(values)}f", *values)


def _insert_node_with_embedding(
    conn,
    *,
    nid: int,
    label: str = "test",
    domain: str = "test",
    vector: list[float],
) -> None:
    """Insert a node with an embedding into both nodes and vec_nodes tables."""
    now = time.time()
    blob = _float32_blob(vector[:512])
    # `uuid` is written here because production writes one on every insert
    # (store.add_node, task 5.14) and PR6a resolves edges through endpoint
    # uuids — a uuid-less node has no readable edges at all. This helper pins
    # an explicit `id`, so it cannot go through add_node.
    conn.execute(
        "INSERT INTO nodes(id, kind, label, data, domain, created_at, updated_at, "
        "embedding, embedding_model, embedding_dim, uuid) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (nid, "fact", label, "{}", domain, now, now, blob, "test-model", 512,
         str(_uuid.uuid4())),
    )
    conn.execute(
        "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
        (nid, blob),
    )
    conn.commit()


def test_similar_to_edges_created_above_threshold(monkeypatch):
    """Task 2.5 RED: nodes A+B with cosine 0.91, threshold 0.85 → edge created."""
    import axi.store as store
    from axi.store import check_and_create_similar_to_edges

    conn = store._connect()
    dim = 512
    vec_a = [1.0] + [0.0] * (dim - 1)
    vec_b = [1.0] + [0.0] * (dim - 1)  # identical = cosine 1.0

    _insert_node_with_embedding(conn, nid=1, label="node A", vector=vec_a)
    _insert_node_with_embedding(conn, nid=2, label="node B", vector=vec_b)

    # Mock knn_nodes to return [(node_id=2, distance=0.09)] (distance = 1 - cosine).
    # vec0 returns cosine DISTANCE (1 - similarity), so 0.09 → similarity 0.91.
    def mock_knn_with_distance(c, *, vector, k=10):
        # Return (node_id, distance) pairs — check_and_create will filter by threshold.
        return [(2, 0.09)]  # cosine similarity = 1 - 0.09 = 0.91

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        check_and_create_similar_to_edges(1, conn, threshold=0.85)

    row = conn.execute(
        "SELECT id FROM edges WHERE from_id=1 AND to_id=2 AND kind='similar-to'"
    ).fetchone()
    assert row is not None, "similar-to edge A→B not created (cosine 0.91 >= 0.85)"


def test_similar_to_edges_not_created_below_threshold(monkeypatch):
    """Task 2.5 RED: nodes A+C with cosine 0.72, threshold 0.85 → no edge."""
    import axi.store as store
    from axi.store import check_and_create_similar_to_edges

    conn = store._connect()
    dim = 512
    _insert_node_with_embedding(conn, nid=3, label="node A2", vector=[1.0] + [0.0] * (dim - 1))
    _insert_node_with_embedding(conn, nid=4, label="node C", vector=[0.0, 1.0] + [0.0] * (dim - 2))

    # cosine distance 0.28 → similarity 0.72 (below 0.85)
    def mock_knn_with_distance(c, *, vector, k=10):
        return [(4, 0.28)]

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        check_and_create_similar_to_edges(3, conn, threshold=0.85)

    row = conn.execute(
        "SELECT id FROM edges WHERE from_id=3 AND to_id=4 AND kind='similar-to'"
    ).fetchone()
    assert row is None, "no edge expected when cosine 0.72 < threshold 0.85"


def test_similar_to_edges_created_with_lower_threshold(monkeypatch):
    """Task 2.5 RED: threshold 0.75, cosine 0.78 → edge IS created."""
    import axi.store as store
    from axi.store import check_and_create_similar_to_edges

    conn = store._connect()
    dim = 512
    _insert_node_with_embedding(conn, nid=5, label="node X", vector=[1.0] + [0.0] * (dim - 1))
    _insert_node_with_embedding(conn, nid=6, label="node Y", vector=[1.0] + [0.0] * (dim - 1))

    # distance 0.22 → similarity 0.78 (>= 0.75 but < 0.85)
    def mock_knn_with_distance(c, *, vector, k=10):
        return [(6, 0.22)]

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        check_and_create_similar_to_edges(5, conn, threshold=0.75)

    row = conn.execute(
        "SELECT id FROM edges WHERE from_id=5 AND to_id=6 AND kind='similar-to'"
    ).fetchone()
    assert row is not None, "edge expected when cosine 0.78 >= threshold 0.75"


def test_similar_to_edges_no_self_link(monkeypatch):
    """Task 2.5 RED: node should not create a similar-to edge to itself."""
    import axi.store as store
    from axi.store import check_and_create_similar_to_edges

    conn = store._connect()
    dim = 512
    _insert_node_with_embedding(conn, nid=7, label="self node", vector=[1.0] + [0.0] * (dim - 1))

    # knn might return the node itself with distance 0.0
    def mock_knn_with_distance(c, *, vector, k=10):
        return [(7, 0.0)]  # self, distance = 0

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        check_and_create_similar_to_edges(7, conn, threshold=0.85)

    row = conn.execute(
        "SELECT id FROM edges WHERE from_id=7 AND to_id=7 AND kind='similar-to'"
    ).fetchone()
    assert row is None, "self-link must not be created"


def test_similar_to_edges_idempotent(monkeypatch):
    """Task 2.5 RED: calling check_and_create_similar_to_edges twice does not duplicate edges."""
    import axi.store as store
    from axi.store import check_and_create_similar_to_edges

    conn = store._connect()
    dim = 512
    _insert_node_with_embedding(conn, nid=8, label="node P", vector=[1.0] + [0.0] * (dim - 1))
    _insert_node_with_embedding(conn, nid=9, label="node Q", vector=[1.0] + [0.0] * (dim - 1))

    def mock_knn_with_distance(c, *, vector, k=10):
        return [(9, 0.05)]  # similarity 0.95

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        check_and_create_similar_to_edges(8, conn, threshold=0.85)
        check_and_create_similar_to_edges(8, conn, threshold=0.85)

    count = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE from_id=8 AND to_id=9 AND kind='similar-to'"
    ).fetchone()[0]
    assert count == 1, f"expected 1 edge, found {count} (idempotency failure)"
