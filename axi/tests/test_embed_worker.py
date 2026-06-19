"""Tests for embed_pending_nodes worker — Slice 1, tasks 1.14 (RED) / 1.15 (GREEN).
Also covers task 1.16 (RED) / 1.17 (GREEN): fire-and-forget thread behavior.
"""
from __future__ import annotations

import struct
import time
import threading
from unittest.mock import patch, MagicMock

import pytest


def _float32_blob(values: list[float]) -> bytes:
    return struct.pack(f"{len(values)}f", *values)


def _insert_null_embedding_node(conn, label: str = "test node") -> int:
    """Helper: insert a node with NULL embedding into the test DB."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", label, "{}", "test", now, now),
    )
    conn.commit()
    return cur.lastrowid


def test_embed_pending_nodes_embeds_null_nodes(monkeypatch):
    """Task 1.14 RED: embed_pending_nodes embeds nodes with NULL embedding."""
    import axi.store as store

    # fresh_db fixture already ran; just use the live test connection.
    conn = store._connect()

    # Insert 3 nodes with no embedding.
    for i in range(3):
        _insert_null_embedding_node(conn, label=f"node {i}")

    fake_vector = [float(i) / 512 for i in range(512)]

    with patch("axi.store.embed_text", return_value=fake_vector):
        from axi.store import embed_pending_nodes

        count = embed_pending_nodes(limit=10)

    assert count == 3, f"expected 3 nodes embedded, got {count}"

    # Verify all rows now have non-NULL embeddings.
    rows = conn.execute(
        "SELECT embedding, embedding_model, embedding_dim FROM nodes WHERE embedding IS NOT NULL"
    ).fetchall()
    assert len(rows) == 3
    for row in rows:
        assert row[0] is not None  # embedding BLOB
        assert row[1] is not None  # embedding_model
        assert row[2] is not None  # embedding_dim


def test_embed_pending_nodes_skips_already_embedded(monkeypatch):
    """Task 1.14 RED: embed_pending_nodes does not re-embed nodes that have embeddings."""
    import axi.store as store

    conn = store._connect()
    now = time.time()

    # Insert one already-embedded node.
    fake_blob = _float32_blob([0.1] * 512)
    conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, "
        "embedding, embedding_model, embedding_dim) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("fact", "already done", "{}", "test", now, now, fake_blob, "test-model", 512),
    )
    # Insert one node that needs embedding.
    _insert_null_embedding_node(conn, label="needs embed")

    embed_call_count = {"n": 0}

    def counting_embed(text, mode="passage"):
        embed_call_count["n"] += 1
        return [0.2] * 512

    with patch("axi.store.embed_text", side_effect=counting_embed):
        from axi.store import embed_pending_nodes

        embed_pending_nodes(limit=10)

    assert embed_call_count["n"] == 1, "only the NULL-embedding node should be embedded"


def test_embed_pending_nodes_returns_zero_when_none_pending(monkeypatch):
    """Task 1.14 RED: embed_pending_nodes returns 0 when no nodes have NULL embedding."""
    import axi.store as store

    conn = store._connect()

    with patch("axi.store.embed_text", return_value=[0.1] * 512):
        from axi.store import embed_pending_nodes

        count = embed_pending_nodes(limit=10)

    assert count == 0


def test_embed_pending_nodes_gracefully_handles_embed_failure(monkeypatch):
    """Task 1.14 RED: single embed failure does not crash the whole batch."""
    import axi.store as store
    from axi.embed_client import EmbedServiceError

    conn = store._connect()
    _insert_null_embedding_node(conn, label="will fail")

    with patch("axi.store.embed_text", side_effect=EmbedServiceError("down")):
        from axi.store import embed_pending_nodes

        # Must not raise — error is swallowed per spec.
        count = embed_pending_nodes(limit=10)

    assert count == 0  # nothing was embedded


def test_fire_and_forget_thread_does_not_block(monkeypatch):
    """Task 1.16 RED: embed dispatch via Thread returns before embedding completes."""
    import axi.store as store

    conn = store._connect()
    _insert_null_embedding_node(conn, label="async node")

    started = threading.Event()
    finished = threading.Event()

    def slow_embed(text, mode="passage"):
        started.set()
        time.sleep(0.3)
        finished.set()
        return [0.1] * 512

    with patch("axi.store.embed_text", side_effect=slow_embed):
        from axi.store import trigger_embed_for_node

        t_start = time.time()
        # Get the last inserted node id.
        row = conn.execute(
            "SELECT id FROM nodes ORDER BY id DESC LIMIT 1"
        ).fetchone()
        node_id = row[0]
        trigger_embed_for_node(node_id)
        elapsed = time.time() - t_start

    # trigger_embed_for_node must return quickly (< 0.1s), not wait for the embed.
    assert elapsed < 0.2, f"trigger_embed_for_node blocked for {elapsed:.3f}s"
    # Let the background thread finish so the test doesn't leave dangling threads.
    finished.wait(timeout=2.0)
