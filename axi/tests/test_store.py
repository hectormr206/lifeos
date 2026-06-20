"""Tests for the SQLite-backed knowledge store."""
from __future__ import annotations

import struct
import time
from unittest.mock import patch

import pytest

from axi import store


def test_add_node_returns_id():
    nid = store.add_node("fact", "Héctor usa HyperX", domain="setup")
    assert isinstance(nid, int)
    assert nid > 0


def test_get_node_round_trips():
    nid = store.add_node("person", "Héctor", {"city": "Mexico"})
    row = store.get_node(nid)
    assert row is not None
    assert row["label"] == "Héctor"
    assert row["kind"] == "person"


def test_fts_finds_inserted_node():
    store.add_node("fact", "Axi corre en CachyOS", domain="setup")
    hits = store.search_nodes_fts("Axi")
    assert len(hits) == 1
    assert "Axi" in hits[0]["label"]


def test_add_edge_and_neighbors():
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "tiene laptop CachyOS")
    store.add_edge(src, dst, "owns")
    found = store.neighbors(src, edge_kind="owns")
    assert len(found) == 1
    assert found[0]["id"] == dst


def test_add_conversation_and_recent():
    cid1 = store.add_conversation("hola", "qué tal")
    time.sleep(0.01)
    cid2 = store.add_conversation("¿qué hora es?", "07:30")
    rows = store.recent_conversations(limit=10)
    # Oldest first per the API contract.
    assert [r["id"] for r in rows] == [cid1, cid2]


def test_clear_conversations_wipes_chat_only():
    nid = store.add_node("fact", "preservar")
    store.add_conversation("a", "b")
    store.add_conversation("c", "d")
    n_dropped = store.clear_conversations()
    assert n_dropped == 2
    assert store.conversation_count() == 0
    # Graph node survives — long-term memory is untouched.
    assert store.get_node(nid) is not None


def test_created_tz_is_recorded():
    nid = store.add_node("fact", "test fact", domain="setup")
    row = store.get_node(nid)
    # Whatever the config says, the column should not be NULL.
    assert row["created_tz"] is not None


# ──────────────────────────────────────────────────────────────────────────────
# FIX 3: vec_nodes ↔ nodes atomicity — failure in upsert_vec_node must
#         roll back (or clear) nodes.embedding so the node stays re-queueable.
# ──────────────────────────────────────────────────────────────────────────────

def test_embed_pending_nodes_rolls_back_embedding_on_vec_upsert_failure():
    """FIX 3 RED: if upsert_vec_node raises, nodes.embedding must end up NULL.

    Without this fix a crash between the nodes UPDATE and the vec_nodes INSERT
    leaves nodes.embedding set but no vec_nodes row — the node is silently lost
    from all future KNN queries because embed_pending_nodes skips embedded nodes.
    """
    nid = store.add_node("fact", "atomic test node", domain="setup")

    # Patch upsert_vec_node to raise after the nodes UPDATE has been committed.
    with patch.object(store, "upsert_vec_node", side_effect=RuntimeError("simulated vec failure")):
        with patch.object(store, "embed_text", return_value=[0.1] * 512):
            embedded = store.embed_pending_nodes(limit=1)

    # The embed should have been skipped (count = 0) OR the node embedding must be NULL.
    row = store.get_node(nid)
    assert row is not None

    # Core invariant: node must be re-queueable (embedding IS NULL) after a vec failure.
    assert row["embedding"] is None, (
        "After upsert_vec_node failure, nodes.embedding must be NULL so the node "
        "re-queues on the next embed_pending_nodes call. Got non-NULL embedding — "
        "torn state detected (FIX 3 not applied)."
    )


# ──────────────────────────────────────────────────────────────────────────────
# FIX 4: vec_nodes orphan cleanup on node DELETE
# ──────────────────────────────────────────────────────────────────────────────

def test_delete_node_removes_vec_nodes_row():
    """FIX 4 RED: deleting a node must also remove its vec_nodes row.

    vec0 virtual tables do not honor SQLite FK ON DELETE CASCADE, so dangling
    rowids pollute KNN results unless explicitly cleaned up.
    """
    c = store._connect()

    # Insert node + embedding.
    nid = store.add_node("fact", "vec orphan test", domain="setup")
    vector = [0.0] * 512
    vector[0] = 1.0  # unit vector
    store.upsert_vec_node(c, node_id=nid, vector=vector)

    # Confirm vec_nodes row exists before deletion.
    before = c.execute(
        "SELECT 1 FROM vec_nodes WHERE node_id = ?", (nid,)
    ).fetchone()
    assert before is not None, "vec_nodes row should exist before DELETE"

    # Delete the node.
    with store._tx() as txc:
        txc.execute("DELETE FROM nodes WHERE id = ?", (nid,))

    # vec_nodes row must be gone too.
    after = c.execute(
        "SELECT 1 FROM vec_nodes WHERE node_id = ?", (nid,)
    ).fetchone()
    assert after is None, (
        "vec_nodes row still exists after node DELETE — orphan detected (FIX 4 not applied)"
    )


def test_knn_does_not_return_deleted_node():
    """FIX 4: KNN must not return a node that has been deleted."""
    c = store._connect()

    nid = store.add_node("fact", "knn orphan check", domain="setup")
    vector = [0.0] * 512
    vector[1] = 1.0  # unit vector
    store.upsert_vec_node(c, node_id=nid, vector=vector)

    # Delete the node.
    with store._tx() as txc:
        txc.execute("DELETE FROM nodes WHERE id = ?", (nid,))

    # KNN with the same vector must not include the deleted node.
    results = store.knn_nodes(c, vector=vector, k=10)
    assert nid not in results, (
        f"Deleted node {nid} still appears in KNN results — orphan vec_nodes row (FIX 4)"
    )


# ──────────────────────────────────────────────────────────────────────────────
# FIX 5: embed worker service-down → nodes remain re-queueable
# ──────────────────────────────────────────────────────────────────────────────

def test_embed_pending_nodes_service_down_leaves_embedding_null():
    """FIX 5 RED: when the embed service is down, nodes stay embedding IS NULL.

    Nodes must NOT be marked as embedded when the embed call fails — they must
    remain re-queueable so the next drain picks them up.
    """
    from axi.embed_client import EmbedServiceError

    nid = store.add_node("fact", "service down test", domain="setup")

    with patch.object(store, "embed_text", side_effect=EmbedServiceError("service down")):
        count = store.embed_pending_nodes(limit=1)

    assert count == 0, "embed_pending_nodes must return 0 when service is down"

    row = store.get_node(nid)
    assert row["embedding"] is None, (
        "Node embedding must remain NULL when embed service is down — "
        "it must stay re-queueable for the next drain"
    )


# ──────────────────────────────────────────────────────────────────────────────
# FIX 5: shared background embed worker
# ──────────────────────────────────────────────────────────────────────────────

def test_trigger_embed_for_node_does_not_spawn_unbounded_threads():
    """FIX 5: trigger_embed_for_node must use a shared worker, not a new thread per call."""
    import threading

    before = threading.active_count()

    # Call trigger multiple times — a shared worker starts only once.
    nid = store.add_node("fact", "worker thread test", domain="setup")
    for _ in range(10):
        store.trigger_embed_for_node(nid)

    after = threading.active_count()
    # Should start at most 1 new thread (the shared worker), not 10.
    new_threads = after - before
    assert new_threads <= 1, (
        f"trigger_embed_for_node started {new_threads} new threads for 10 calls — "
        "must use a shared worker queue, not thread-per-node (FIX 5 not applied)"
    )


def test_run_periodic_embed_drain_exists():
    """FIX 5: run_periodic_embed_drain must be importable from axi.store."""
    from axi.store import run_periodic_embed_drain
    assert callable(run_periodic_embed_drain)


# ──────────────────────────────────────────────────────────────────────────────
# FIX 6: thread-local connections — the bug that caused real B-tree corruption
# ──────────────────────────────────────────────────────────────────────────────

def test_concurrent_writes_no_corruption():
    """FIX 6 RED: concurrent writes from multiple threads must not corrupt the DB.

    This is the test that would have caught the real corruption incident:
    the FIX-5 embed worker thread + periodic drain + FastAPI request threads
    all shared a single SQLite connection (check_same_thread=False, no global
    lock around every statement).  Two threads executing on the SAME connection
    concurrently caused B-tree corruption ('rowid out of order' → 'database
    disk image is malformed').

    Fix: thread-local connections — each thread gets its own sqlcipher3
    connection.  This test verifies the fix by running concurrent writes and
    asserting PRAGMA integrity_check returns 'ok' after the load.
    """
    import threading

    errors: list[Exception] = []
    node_ids: list[int] = []
    lock = threading.Lock()

    def writer(label: str) -> None:
        # Each thread calls store functions that obtain a thread-local connection.
        # If two threads shared the same connection object this would corrupt.
        try:
            for i in range(10):
                nid = store.add_node("fact", f"{label}-{i}", domain="concurrency-test")
                with lock:
                    node_ids.append(nid)
                # Also do a read on the same connection to interleave read+write.
                store.get_node(nid)
        except Exception as exc:  # noqa: BLE001
            with lock:
                errors.append(exc)

    threads = [threading.Thread(target=writer, args=(f"thread-{t}",)) for t in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert not errors, f"Concurrent write errors: {errors}"

    # After the concurrent load, integrity_check must pass on the main thread's
    # connection — this is the definitive proof that no corruption occurred.
    c = store._connect()
    result = c.execute("PRAGMA integrity_check").fetchone()[0]
    assert result == "ok", f"DB integrity_check failed after concurrent writes: {result}"

    # All 40 written nodes must be queryable.
    assert len(node_ids) == 40
    for nid in node_ids:
        assert store.get_node(nid) is not None, f"Node {nid} missing after concurrent write"


def test_each_thread_gets_own_connection():
    """FIX 6: _connect() must return a DIFFERENT connection object per thread.

    The root cause of the corruption was that _connect() returned the same
    module-level singleton to all threads.  This test asserts the thread-local
    model: two threads must get different connection objects.
    """
    import threading

    connections: list[object] = []
    lock = threading.Lock()

    def capture_conn() -> None:
        c = store._connect()
        with lock:
            connections.append(id(c))

    main_conn_id = id(store._connect())
    t = threading.Thread(target=capture_conn)
    t.start()
    t.join(timeout=5)

    assert len(connections) == 1
    assert connections[0] != main_conn_id, (
        "Both main thread and child thread got the same connection object — "
        "thread-local isolation is NOT in effect (FIX 6 not applied)"
    )


def test_new_thread_can_query_vec_nodes():
    """FIX 6: a fresh thread's _connect() must be able to query vec_nodes.

    Without loading sqlite-vec on every new connection, any thread other than
    the one that called init_db() would see 'no such module: vec0' and crash
    when trying to use the vec_nodes virtual table.
    """
    import threading

    errors: list[Exception] = []

    def query_vec_nodes() -> None:
        try:
            c = store._connect()
            # This SELECT hits the vec0 virtual table engine.
            # It raises 'no such module: vec0' if the extension is not loaded.
            c.execute("SELECT count(*) FROM vec_nodes").fetchone()
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    t = threading.Thread(target=query_vec_nodes)
    t.start()
    t.join(timeout=5)

    assert not errors, (
        f"New thread could not query vec_nodes (sqlite-vec not loaded per thread): {errors}"
    )
