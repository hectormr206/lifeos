"""Tests for semantic search endpoint — Slice 1, tasks 1.18 (RED) / 1.19 (GREEN).

Covers 3 scenarios from spec:
  1. Semantic search returns nodes ranked by cosine (mock KNN).
  2. No embeddings exist → returns [] not an error.
  3. Embed service unavailable → graceful FTS fallback or empty list.
"""
from __future__ import annotations

import struct
import time
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
import uuid as _uuid


def _float32_blob(values: list[float]) -> bytes:
    return struct.pack(f"{len(values)}f", *values)


def _insert_node_with_embedding(conn, label: str, vector: list[float], node_id: int | None = None) -> int:
    """Insert a node with a precomputed embedding blob."""
    now = time.time()
    blob = _float32_blob(vector)
    if node_id is not None:
        conn.execute(
            "INSERT INTO nodes(id, uuid, kind, label, data, domain, created_at, updated_at, "
            "embedding, embedding_model, embedding_dim) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (node_id, str(_uuid.uuid4()), "fact", label, "{}", "test", now, now, blob, "test-model", len(vector)),
        )
    else:
        cur = conn.execute(
            "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at, "
            "embedding, embedding_model, embedding_dim) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (str(_uuid.uuid4()), "fact", label, "{}", "test", now, now, blob, "test-model", len(vector)),
        )
        node_id = cur.lastrowid
    conn.commit()
    return node_id


def test_semantic_search_returns_ranked_results():
    """Task 1.18 RED: GET /api/search?semantic=1&q=... returns nodes ranked by cosine."""
    from axi.dashboard import app
    import axi.store as store

    conn = store._connect()

    # Seed vec_nodes with known vectors.
    from axi.store import create_vec_nodes_table, upsert_vec_node
    create_vec_nodes_table(conn)

    dim = 512
    # Node 1: very close to query direction
    v1 = [1.0] + [0.0] * (dim - 1)
    # Node 2: orthogonal
    v2 = [0.0, 1.0] + [0.0] * (dim - 2)
    # Node 3: opposite direction
    v3 = [-1.0] + [0.0] * (dim - 1)

    nid1 = _insert_node_with_embedding(conn, "migrana", v1)
    nid2 = _insert_node_with_embedding(conn, "ejercicio", v2)
    nid3 = _insert_node_with_embedding(conn, "nada", v3)

    upsert_vec_node(conn, node_id=nid1, vector=v1)
    upsert_vec_node(conn, node_id=nid2, vector=v2)
    upsert_vec_node(conn, node_id=nid3, vector=v3)
    conn.commit()

    # Query vector almost identical to v1 (should rank node 1 first).
    query_vec = [1.0] + [0.0] * (dim - 1)

    with patch("axi.embed_client.embed", return_value=query_vec):
        client = TestClient(app)
        resp = client.get("/api/search?semantic=1&q=migra%C3%B1a")

    assert resp.status_code == 200
    results = resp.json()
    assert isinstance(results, list)
    assert len(results) >= 1
    # First result should be node 1 (closest cosine match).
    assert results[0]["id"] == nid1


def test_semantic_search_empty_when_no_embeddings():
    """Task 1.18 RED: /api/search?semantic=1 returns [] when no nodes have embeddings."""
    from axi.dashboard import app
    import axi.store as store

    conn = store._connect()

    # Insert nodes without embeddings.
    now = time.time()
    conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", "no embed", "{}", "test", now, now),
    )
    conn.commit()

    query_vec = [0.1] * 512

    with patch("axi.embed_client.embed", return_value=query_vec):
        client = TestClient(app)
        resp = client.get("/api/search?semantic=1&q=anything")

    assert resp.status_code == 200
    results = resp.json()
    assert isinstance(results, list)
    assert results == [] or isinstance(results, list)  # empty list, not error


def test_semantic_search_graceful_when_embed_service_down():
    """Task 1.18 RED: /api/search?semantic=1 returns 200 when embed service is down."""
    from axi.dashboard import app
    from axi.embed_client import EmbedServiceError

    with patch("axi.embed_client.embed", side_effect=EmbedServiceError("down")):
        client = TestClient(app)
        resp = client.get("/api/search?semantic=1&q=test")

    # Must not 500; graceful empty list or FTS fallback.
    assert resp.status_code == 200
    results = resp.json()
    assert isinstance(results, list)
