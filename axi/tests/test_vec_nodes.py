"""Tests for vec_nodes virtual table — Slice 1, tasks 1.12 (RED) / 1.13 (GREEN).

PoC 0.1 PASSED: sqlite-vec works in sqlcipher3.
→ FORK-VEC path A (vec_nodes vtable). hnswlib NOT needed.

create_vec_nodes_table(conn) must create the vec_nodes virtual table.
knn_nodes(conn, vector, k) must return the k nearest node ids.
"""
from __future__ import annotations

import struct
import time

import pytest
import uuid as _uuid


def _float32_blob(values: list[float]) -> bytes:
    return struct.pack(f"{len(values)}f", *values)


def test_create_vec_nodes_table(tmp_path, monkeypatch):
    """Task 1.12 RED: create_vec_nodes_table creates a vec_nodes virtual table."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    from axi.store import create_vec_nodes_table

    conn = store._connect()
    create_vec_nodes_table(conn)

    # Table must appear in sqlite_master.
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='vec_nodes'"
    ).fetchone()
    assert row is not None, "vec_nodes virtual table was not created"


def test_vec_nodes_insert_and_knn(tmp_path, monkeypatch):
    """Task 1.12 RED: knn_nodes returns nearest node ids by cosine distance."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    from axi.store import create_vec_nodes_table, knn_nodes, upsert_vec_node

    conn = store._connect()
    create_vec_nodes_table(conn)

    # Insert 3 nodes into the nodes table first.
    now = time.time()
    for i in range(3):
        conn.execute(
            "INSERT INTO nodes(id, uuid, kind, label, data, domain, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (i + 1, str(_uuid.uuid4()), "fact", f"node{i}", "{}", "test", now, now),
        )
    conn.commit()

    # Build test vectors: vec_a is close to query; vec_c is far.
    dim = 512
    vec_a = [1.0] + [0.0] * (dim - 1)
    vec_b = [0.0, 1.0] + [0.0] * (dim - 2)
    vec_c = [-1.0] + [0.0] * (dim - 1)

    upsert_vec_node(conn, node_id=1, vector=vec_a)
    upsert_vec_node(conn, node_id=2, vector=vec_b)
    upsert_vec_node(conn, node_id=3, vector=vec_c)
    conn.commit()

    # Query closest to vec_a.
    query_vec = [1.0] + [0.0] * (dim - 1)
    results = knn_nodes(conn, vector=query_vec, k=2)

    assert len(results) >= 1
    # Node 1 (vec_a, closest to query) should be first.
    assert results[0] == 1


def test_vec_nodes_created_on_init_db(tmp_path, monkeypatch):
    """Task 1.13 GREEN: vec_nodes table exists after init_db (wired in startup)."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    conn = store._connect()
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='vec_nodes'"
    ).fetchone()
    assert row is not None, "vec_nodes must exist after init_db()"
