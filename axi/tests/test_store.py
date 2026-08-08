"""Tests for the SQLite-backed knowledge store."""
from __future__ import annotations

import struct
import time
from unittest.mock import patch

import pytest

from axi import store
import uuid as _uuid


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


def test_add_node_assigns_a_uuid_at_insert_time():
    """A node must carry its sync identity from the moment it exists.

    PR4 added `nodes.uuid` and a startup backfill; nothing ever assigned one on
    insert. So every node created between two restarts had `uuid IS NULL`, and
    every edge touching it dual-wrote `src_uuid IS NULL` — which
    `verify_edge_endpoint_convergence` reports as CONVERGED, because NULL does
    equal NULL. The guard is blind to exactly the window it exists to watch.

    That is fine while nothing reads the column. PR6 makes readers resolve
    edges through `src_uuid`, at which point a NULL means the edge is invisible
    — the user's memory silently missing a link. Assigning at insert closes the
    window instead of relying on the next boot to notice.
    """
    nid = store.add_node("person", "Héctor")

    row = store._connect().execute(
        "SELECT uuid FROM nodes WHERE id=?", (nid,)
    ).fetchone()
    assert row["uuid"] is not None, "a freshly inserted node has no sync identity"
    assert len(row["uuid"]) == 36  # canonical uuid4, not a placeholder


def test_edges_of_freshly_created_nodes_never_dual_write_null():
    """The end-to-end version of the above: no backfill call, no staging.

    If this needs `migrate_nodes_edges_sync_columns()` to pass, the dual-write
    is only working in tests that stage it — not in the running daemon.
    """
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    eid = store.add_edge(src, dst, "owns")

    row = store._connect().execute(
        "SELECT src_uuid, dst_uuid FROM edges WHERE id=?", (eid,)
    ).fetchone()
    assert row["src_uuid"] is not None
    assert row["dst_uuid"] is not None


def test_add_edge_dual_writes_src_dst_uuid():
    """Task 5.5 RED: `add_edge` writes the endpoint uuids.

    PR5 called this a DUAL write against the still-authoritative
    `from_id`/`to_id`. PR8 dropped those, so `src_uuid`/`dst_uuid` are simply
    the endpoints now — and being `NOT NULL`, an edge that fails to write them
    does not exist rather than existing unreadably.

    The backfill call below is kept deliberately: `add_node` now assigns a uuid
    at insert time, so it is a no-op here, and running it anyway proves the
    dual-write agrees with the backfill's result rather than racing it. See
    `test_edges_of_freshly_created_nodes_never_dual_write_null` for the same
    property with no staging at all.
    """
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "tiene laptop CachyOS")
    store.migrate_nodes_edges_sync_columns()  # no-op now; pins that it stays one
    eid = store.add_edge(src, dst, "owns")

    c = store._connect()
    src_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (src,)).fetchone()[0]
    dst_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (dst,)).fetchone()[0]
    row = c.execute(
        "SELECT src_uuid, dst_uuid FROM edges WHERE id=?", (eid,)
    ).fetchone()
    assert row["src_uuid"] == src_uuid
    assert row["dst_uuid"] == dst_uuid
    assert src_uuid is not None and dst_uuid is not None

    # No drift, proven the same way PR5's own convergence check proves it.
    store.verify_edge_endpoint_convergence()


def test_similar_to_edge_insert_dual_writes_src_dst_uuid():
    """Task 5.6 RED: the similar-to edge insert writes the endpoint uuids.

    PR5 called this a DUAL write, alongside `from_id`/`to_id`. PR8 removed the
    integer endpoints, so it is simply the write now — and the edge also gets
    its own `uuid`, without which `uuid NOT NULL UNIQUE` means the row cannot
    exist at all.
    """
    dim = 512
    now = time.time()
    vec_a = [1.0] + [0.0] * (dim - 1)
    vec_b = [1.0] + [0.0] * (dim - 1)  # identical vector -> cosine 1.0

    c = store._connect()
    for nid, label, vec in ((101, "node A", vec_a), (102, "node B", vec_b)):
        blob = struct.pack(f"{dim}f", *vec)
        c.execute(
            "INSERT INTO nodes(id, uuid, kind, label, data, domain, created_at, "
            "updated_at, embedding, embedding_model, embedding_dim) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (nid, f"uuid-{nid}", "fact", label, "{}", "test", now, now, blob,
             "test-model", dim),
        )
        c.execute(
            "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
            (nid, blob),
        )
    c.commit()

    def mock_knn_with_distance(conn, *, vector, k=10):
        return [(102, 0.0)]  # cosine similarity 1.0

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        store.check_and_create_similar_to_edges(101, c, threshold=0.85)

    row = c.execute(
        "SELECT uuid, src_uuid, dst_uuid FROM edges "
        "WHERE src_uuid='uuid-101' AND dst_uuid='uuid-102' "
        "AND relation='similar-to'"
    ).fetchone()
    assert row is not None
    assert row["src_uuid"] == "uuid-101"
    assert row["dst_uuid"] == "uuid-102"
    assert row["uuid"] is not None


def test_add_conversation_and_recent():
    cid1 = store.add_conversation("hola", "qué tal")
    time.sleep(0.01)
    cid2 = store.add_conversation("¿qué hora es?", "07:30")
    rows = store.recent_conversations(limit=10)
    # Oldest first per the API contract.
    assert [r["id"] for r in rows] == [cid1, cid2]


def test_conversation_source_tags_and_chat_filter():
    """Turns carry a source ('chat' default | 'voice'); the chat-history filter
    (COALESCE(source,'chat') != 'voice') hides voice turns but keeps chat ones."""
    cid_chat = store.add_conversation("hola", "qué tal")            # default 'chat'
    cid_voice = store.add_conversation("axi qué hora", "07:30", source="voice")
    c = store._connect()  # noqa: SLF001
    src = {r["id"]: r["source"] for r in c.execute("SELECT id, source FROM conversations")}
    assert src[cid_chat] == "chat"
    assert src[cid_voice] == "voice"
    shown = [r["id"] for r in c.execute(
        "SELECT id FROM conversations WHERE COALESCE(source,'chat') != 'voice' ORDER BY id"
    )]
    assert cid_chat in shown and cid_voice not in shown


def test_delete_conversation_removes_one_turn():
    a = store.add_conversation("hola", "qué tal")
    b = store.add_conversation("otra cosa", "ok")
    assert store.delete_conversation(a) is True
    ids = [r["id"] for r in store.recent_conversations(limit=10)]
    assert a not in ids and b in ids                 # only the targeted turn is gone
    assert store.delete_conversation(999999) is False  # nonexistent row → False


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


def test_drain_ingests_domain_facts(monkeypatch):
    """The periodic drain must auto-ingest new domain entries into the graph.

    Without this, fact-nodes only ever appear via the manual backfill CLI, so
    the graph goes stale between manual runs. The drain must call
    domain_bridge.backfill_all_domains (bounded) so a freshly logged health /
    finance / relationships entry becomes a graph node on the next tick.
    """
    import axi.domain_bridge as domain_bridge

    calls: list[dict] = []
    monkeypatch.setattr(
        domain_bridge, "backfill_all_domains",
        lambda **kw: calls.append(kw) or {},
    )
    # Stub the remaining drain steps so this test isolates ingestion.
    monkeypatch.setattr(store, "embed_pending_nodes", lambda **kw: None)
    monkeypatch.setattr(store, "backfill_similar_to_edges", lambda **kw: None)

    with patch.dict("sys.modules", {"axi.linkers": __import__("unittest.mock", fromlist=["MagicMock"]).MagicMock()}):
        import axi.linkers as linkers_mod
        linkers_mod.run_auto_linkers = lambda *a, **k: None
        with patch("axi.store._connect", return_value=__import__("unittest.mock", fromlist=["MagicMock"]).MagicMock()):
            store.run_periodic_embed_drain()

    assert calls, "run_periodic_embed_drain did not call backfill_all_domains"
    # Must be bounded so a 5-minute tick can't do unbounded work.
    assert calls[0].get("node_limit") is not None, "domain backfill in the drain must be bounded (node_limit)"


def test_drain_domain_backfill_failure_emits_warning(monkeypatch):
    """If domain ingestion raises, the drain logs an embed.drain warning and keeps going."""
    import axi.domain_bridge as domain_bridge
    import axi.events as events_mod

    warnings: list[tuple] = []
    monkeypatch.setattr(events_mod, "log_warning", lambda source, msg, data=None: warnings.append((source, msg, data)))
    monkeypatch.setattr(
        domain_bridge, "backfill_all_domains",
        lambda **kw: (_ for _ in ()).throw(RuntimeError("domain fetch failed")),
    )
    monkeypatch.setattr(store, "embed_pending_nodes", lambda **kw: None)
    monkeypatch.setattr(store, "backfill_similar_to_edges", lambda **kw: None)

    with patch.dict("sys.modules", {"axi.linkers": __import__("unittest.mock", fromlist=["MagicMock"]).MagicMock()}):
        import axi.linkers as linkers_mod
        linkers_mod.run_auto_linkers = lambda *a, **k: None
        with patch("axi.store._connect", return_value=__import__("unittest.mock", fromlist=["MagicMock"]).MagicMock()):
            store.run_periodic_embed_drain()  # must NOT raise

    assert any(c[0] == "embed.drain" for c in warnings), f"No embed.drain warning emitted; got: {warnings}"


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


# ─────────── PR6a: reader rewrite to src_uuid/dst_uuid/relation ───────────
#
# Every test below pins ONE of the two claims PR6a makes:
#
#   1. the read now resolves an edge through its sync-stable endpoint uuids,
#      not through the local integer rowids (proven by desyncing the two and
#      showing which one the reader follows), and
#   2. on a clean graph it returns EXACTLY what the pre-rewrite SQL returned
#      (proven against the literal old query kept here as an oracle, not by
#      the weaker "the suite still passes").

# PR7 note on these oracles: `deleted_at IS NULL` was added to all three.
#
# They are the PRE-REWRITE query, kept to prove that resolving an edge through
# `src_uuid`/`dst_uuid` returns exactly what resolving it through
# `from_id`/`to_id` returned. That claim is about the ENDPOINT COLUMNS and it
# still holds unchanged. PR7 changes a different thing — a tombstoned row is
# now invisible — and that change applies to the old columns just as much as
# to the new ones. Leaving the filter off the oracle would have made it assert
# "the rewrite kept PR6a's tombstone behaviour", which is not what it is for
# and is exactly the expectation PR7 deliberately breaks. Tombstone
# invisibility gets its own tests below; this one stays a column-equivalence
# oracle.
_OLD_NEIGHBORS_KIND_SQL = (
    "SELECT n.* FROM nodes n JOIN edges e ON n.uuid = e.dst_uuid "
    "WHERE e.src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND e.relation = ? "
    "AND e.deleted_at IS NULL AND n.deleted_at IS NULL"
)
_OLD_NEIGHBORS_ANY_SQL = (
    "SELECT n.* FROM nodes n JOIN edges e ON n.uuid = e.dst_uuid "
    "WHERE e.src_uuid=(SELECT uuid FROM nodes WHERE id=?) "
    "AND e.deleted_at IS NULL AND n.deleted_at IS NULL"
)
_OLD_SAME_DAY_SQL = """
    SELECT n.id, n.kind, n.label, n.domain, n.data, n.created_at, n.occurred_at
    FROM nodes n
    JOIN edges e ON e.src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND n.uuid = e.dst_uuid AND e.relation = 'same-day'
    WHERE n.id != ? AND e.deleted_at IS NULL AND n.deleted_at IS NULL
    UNION
    SELECT n.id, n.kind, n.label, n.domain, n.data, n.created_at, n.occurred_at
    FROM nodes n
    JOIN edges e ON e.dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND n.uuid = e.src_uuid AND e.relation = 'same-day'
    WHERE n.id != ? AND e.deleted_at IS NULL AND n.deleted_at IS NULL
"""


def _rows(cursor) -> list[dict]:
    """Order-insensitive comparable form — a uuid join may pick a different
    query plan than a rowid join, and row ORDER was never part of the
    contract; row CONTENT and multiplicity are."""
    return sorted((dict(r) for r in cursor), key=lambda d: sorted(d.items(), key=str))


def test_neighbors_resolves_edges_through_src_uuid_not_from_id():
    """6a.1's claim, now provable structurally instead of behaviourally.

    This test used to point the edge's integer `from_id` at a decoy while
    `src_uuid` still named the real source, so that a reader on the wrong
    column gave the wrong answer. PR8 removed `from_id` outright: there is no
    second representation left to disagree with, which is a STRONGER
    guarantee than the old assertion, not a weaker one — the wrong column
    cannot be read because it does not exist.

    What is asserted instead: the column is genuinely gone, and `src_uuid` is
    genuinely the endpoint — repointing it MOVES the edge, so nothing else is
    quietly deciding which node a relation belongs to.
    """
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    decoy = store.add_node("person", "no es el origen")
    eid = store.add_edge(src, dst, "owns")

    cols = {r[1] for r in store._connect().execute("PRAGMA table_xinfo(edges)").fetchall()}
    assert "from_id" not in cols and "to_id" not in cols

    assert [r["id"] for r in store.neighbors(src, edge_kind="owns")] == [dst]
    store._connect().execute(
        "UPDATE edges SET src_uuid=(SELECT uuid FROM nodes WHERE id=?) WHERE id=?",
        (decoy, eid),
    )
    assert store.neighbors(src, edge_kind="owns") == []
    assert [r["id"] for r in store.neighbors(decoy, edge_kind="owns")] == [dst]


def test_neighbors_resolves_destination_through_dst_uuid_not_to_id():
    """The destination side of the same claim — see the note above."""
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    decoy = store.add_node("fact", "no es el destino")
    eid = store.add_edge(src, dst, "owns")

    assert [r["id"] for r in store.neighbors(src, edge_kind="owns")] == [dst]
    store._connect().execute(
        "UPDATE edges SET dst_uuid=(SELECT uuid FROM nodes WHERE id=?) WHERE id=?",
        (decoy, eid),
    )
    assert [r["id"] for r in store.neighbors(src, edge_kind="owns")] == [decoy]


def test_neighbors_identical_to_pre_rewrite_query_on_pr6a_graph(pr6a_graph):
    """6a.1's "identical results on a seeded fixture DB", taken literally:
    the pre-rewrite SQL is executed here as the oracle and compared row for
    row, including the self-edge, the duplicate-kind pair and the dangling
    endpoint."""
    c = store._connect()
    for node_id in pr6a_graph.values():
        for kind in ("about", "mentions", "involves", "esposa", "same-day"):
            assert _rows(store.neighbors(node_id, edge_kind=kind)) == _rows(
                c.execute(_OLD_NEIGHBORS_KIND_SQL, (node_id, kind))
            ), f"neighbors({node_id}, {kind!r}) diverged from the pre-rewrite query"
        assert _rows(store.neighbors(node_id)) == _rows(
            c.execute(_OLD_NEIGHBORS_ANY_SQL, (node_id,))
        ), f"neighbors({node_id}) diverged from the pre-rewrite query"


def test_same_day_neighbors_resolves_through_endpoint_uuids():
    """RED for 6a.1: `same_day_neighbors` reads BOTH directions, so both
    arms of its UNION have to move to the uuid endpoints."""
    a = store.add_node("fact", "nota A")
    b = store.add_node("fact", "nota B")
    decoy = store.add_node("fact", "señuelo")
    eid = store.add_edge(a, b, "same-day")

    assert [n["id"] for n in store.same_day_neighbors(a)] == [b]
    assert [n["id"] for n in store.same_day_neighbors(b)] == [a]
    assert store.same_day_neighbors(decoy) == []
    # Both arms of the UNION resolve through the endpoint uuids: move the
    # source endpoint and BOTH directions follow it.
    store._connect().execute(
        "UPDATE edges SET src_uuid=(SELECT uuid FROM nodes WHERE id=?) WHERE id=?",
        (decoy, eid),
    )
    assert store.same_day_neighbors(a) == []
    assert [n["id"] for n in store.same_day_neighbors(decoy)] == [b]
    assert [n["id"] for n in store.same_day_neighbors(b)] == [decoy]


def test_same_day_neighbors_identical_to_pre_rewrite_query(pr6a_graph):
    c = store._connect()
    for node_id in pr6a_graph.values():
        old = _rows(c.execute(_OLD_SAME_DAY_SQL, (node_id,) * 4))
        assert _rows(store.same_day_neighbors(node_id)) == old, (
            f"same_day_neighbors({node_id}) diverged from the pre-rewrite query"
        )


def test_similar_to_dedupe_resolves_through_endpoint_uuids():
    """RED for 6a.1: the `similar-to` duplicate guard (store.py:3133) is a
    read, so it moves too. If it kept matching on `from_id` it would fail to
    recognise an edge it had already written and insert a second one."""
    dim = 512
    now = time.time()
    vec = [1.0] + [0.0] * (dim - 1)
    blob = struct.pack(f"{dim}f", *vec)

    c = store._connect()
    for nid, label in ((101, "node A"), (102, "node B"), (103, "decoy")):
        c.execute(
            "INSERT INTO nodes(id, kind, label, data, domain, created_at, "
            "updated_at, embedding, embedding_model, embedding_dim, uuid) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (nid, "fact", label, "{}", "test", now, now, blob, "test-model",
             dim, f"uuid-{nid}"),
        )
        c.execute(
            "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
            (nid, blob),
        )
    # An already-written similar-to edge, addressed the way the graph is
    # addressed now: by endpoint uuid, with no integer endpoint to drift.
    c.execute(
        "INSERT INTO edges(uuid, src_uuid, dst_uuid, relation, data, "
        "created_at, updated_at) "
        "VALUES ('edge-uuid-1', 'uuid-101', 'uuid-102', 'similar-to', '{}', ?, ?)",
        (now, now),
    )

    def mock_knn_with_distance(conn, *, vector, k=10):
        return [(102, 0.0)]

    with patch("axi.store.knn_nodes_with_distance", side_effect=mock_knn_with_distance):
        created = store.check_and_create_similar_to_edges(101, c, threshold=0.85)

    assert created == 0, "the dedupe guard did not recognise the existing edge"
    assert c.execute(
        "SELECT COUNT(*) FROM edges WHERE relation='similar-to'"
    ).fetchone()[0] == 1


def test_edge_with_null_endpoint_uuid_is_detected_loudly_not_silently_dropped():
    """The central hazard of PR6a, pinned so it cannot regress silently.

    Before the rewrite, reads joined `from_id`/`to_id`: NOT NULL integers.
    After it, they join `src_uuid`/`dst_uuid`: nullable TEXT. An edge whose
    endpoint uuid is NULL does not match the join — it disappears from the
    result with no error and no log, which is a link missing from the user's
    own memory graph.

    PR6a took answer (a): NULL endpoints are impossible by construction, and
    the residual case is made LOUD instead of tolerated. PR8 finishes the job
    — `NOT NULL` on `uuid`, `src_uuid` and `dst_uuid` means the state cannot
    be WRITTEN, so it is no longer a hazard that has to be reported. That is
    the difference between "we would notice" and "it cannot happen", and it is
    the whole reason mobile's DDL was the target shape.
    """
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    store.add_edge(src, dst, "owns")

    c = store._connect()
    # PR8 closes the hazard rather than only reporting it: the state cannot be
    # written at all any more. Asserted by trying — the engine refuses both
    # halves of the only route that ever reached it.
    with pytest.raises(Exception):
        c.execute("UPDATE nodes SET uuid=NULL WHERE id=?", (src,))
    with pytest.raises(Exception):
        c.execute(
            "UPDATE edges SET src_uuid=NULL "
            "WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?)", (src,)
        )
    # …and the read still returns the relation, because nothing was lost.
    assert [r["id"] for r in store.neighbors(src, edge_kind="owns")] == [dst]
    store.verify_edge_endpoint_convergence()


def test_convergence_failure_names_the_broken_edge_not_a_row_repr(pre_pr8_graph):
    """Failing loudly is only half of it — the shout has to say what broke.

    The guard interpolated raw sqlite Row objects, so a real production
    failure read `[<sqlcipher3.dbapi2.Row object at 0x7f...>]`: no edge id, no
    uuid, no indication of which side was NULL. That is a check that fires and
    tells you nothing, which in practice sends you to a debugger against a
    database you may not be able to reproduce.

    Run against the PRE-PR8 shape, which is the only place this guard can
    still fire: after the rebuild both branches are impossible by
    construction. That is where the owner's real database will be on the
    morning it migrates, so the message still has to be actionable there.
    """
    eid = pre_pr8_graph["edges"]["esposa"]
    store._connect().execute("UPDATE edges SET dst_uuid=NULL WHERE id=?", (eid,))

    with pytest.raises(RuntimeError) as excinfo:
        store.verify_edge_endpoint_convergence()

    message = str(excinfo.value)
    assert "Row object" not in message, "the diagnostic leaked a repr instead of values"
    assert f"id={eid}" in message, "the failure does not name the offending edge"


def test_drift_failure_also_names_the_edge(pre_pr8_graph):
    """Same contract for the drift branch, which shares the defect. Also on
    the pre-PR8 shape — after the rebuild there is no second endpoint
    representation left to drift from."""
    eid = pre_pr8_graph["edges"]["esposa"]
    store._connect().execute(
        "UPDATE edges SET dst_uuid='not-the-node-uuid' WHERE id=?", (eid,)
    )

    with pytest.raises(RuntimeError) as excinfo:
        store.verify_edge_endpoint_convergence()

    message = str(excinfo.value)
    assert "Row object" not in message
    assert f"id={eid}" in message


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — tombstones (design-schema.md Decision 3, tasks 7.1-7.5, 7.9, 7.11,
# 7.14). A delete stops removing the row and starts marking it. The unit is
# atomic on purpose: the write half alone would leave every deleted memory
# readable again, which is worse than either endpoint.
# ═══════════════════════════════════════════════════════════════════════════


def _row(sql, *params):
    return store._connect().execute(sql, params).fetchone()


def _tombstone_graph():
    """hub -> ana ('esposa'), ana -> fact ('mentions'), plus an untouched pair."""
    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    fact = store.add_node("fact", "hipertensión diagnosticada")
    other = store.add_node("fact", "usa CachyOS")
    e_hub_ana = store.add_edge(hub, ana, "esposa")
    e_ana_fact = store.add_edge(ana, fact, "mentions")
    e_untouched = store.add_edge(hub, other, "about")
    return {
        "hub": hub, "ana": ana, "fact": fact, "other": other,
        "e_hub_ana": e_hub_ana, "e_ana_fact": e_ana_fact,
        "e_untouched": e_untouched,
    }


# ── 7.4 — the node row survives as a tombstone ────────────────────────────

def test_delete_node_tombstones_the_row_instead_of_removing_it():
    """7.4: `DELETE FROM nodes` becomes `UPDATE nodes SET deleted_at`.

    The row must still be there. Sync cannot replicate an absence: a peer that
    never sees the row cannot tell "deleted" from "not yet received", so it
    hands the memory straight back on the next exchange.
    """
    g = _tombstone_graph()
    assert store.delete_node(g["ana"]) is True

    row = _row("SELECT id, deleted_at FROM nodes WHERE id = ?", g["ana"])
    assert row is not None, "the node row was hard-deleted; a tombstone must survive"
    assert row["deleted_at"] is not None
    assert row["deleted_at"] > 0


def test_delete_node_twice_reports_false_the_second_time():
    """The `AND deleted_at IS NULL` guard makes the tombstone write idempotent.

    Without it a second delete would rewrite `deleted_at` to a later timestamp
    and report success, i.e. claim to have deleted something that was already
    gone.
    """
    g = _tombstone_graph()
    assert store.delete_node(g["ana"]) is True
    first = _row("SELECT deleted_at FROM nodes WHERE id = ?", g["ana"])["deleted_at"]
    assert store.delete_node(g["ana"]) is False
    assert _row("SELECT deleted_at FROM nodes WHERE id = ?", g["ana"])["deleted_at"] == first


# ── 7.1 — the node's edges are tombstoned in the SAME transaction ──────────

def test_tombstoning_a_node_bumps_updated_at_so_the_delete_can_win_a_merge():
    """A tombstone IS a write, and last-writer-wins reads `updated_at`.

    Tasks 7.1 and 7.4 came out asymmetric: the edge tombstone sets
    `updated_at`, the node tombstone sets only `deleted_at`. The design table
    shows why — the edge row spells out the full SQL, the node row is a
    one-word placeholder with an empty cell. An omission, not a decision.

    Left alone it resurrects deleted memories. Delete a node here at T=100 and
    its `updated_at` stays at, say, T=10. A peer that merely EDITED the same
    node at T=50 carries a later `updated_at`, so under last-writer-wins the
    edit beats the delete and the memory the user deleted comes back on the
    next sync — silently, and looking like it was never deleted at all.

    Nothing observable changes today: the row is invisible to every read after
    PR7, and there is no sync engine yet. That is exactly why it is cheap to
    fix now and expensive to discover later.
    """
    g = _tombstone_graph()
    before = _row("SELECT updated_at FROM nodes WHERE id = ?", g["ana"])["updated_at"]
    time.sleep(0.01)

    assert store.delete_node(g["ana"]) is True

    row = _row("SELECT deleted_at, updated_at FROM nodes WHERE id = ?", g["ana"])
    assert row["updated_at"] > before, "the tombstone did not count as a write"
    assert row["updated_at"] == row["deleted_at"], (
        "deletion time and last-write time must agree, or a merge can order "
        "the delete against the wrong instant"
    )


def test_delete_node_tombstones_its_edges_in_both_directions():
    """7.1: edges are matched on `src_uuid`/`dst_uuid`, not the rowid pair."""
    g = _tombstone_graph()
    store.delete_node(g["ana"])

    for eid in (g["e_hub_ana"], g["e_ana_fact"]):
        e = _row("SELECT id, deleted_at, updated_at FROM edges WHERE id = ?", eid)
        assert e is not None, f"edge {eid} was hard-deleted instead of tombstoned"
        assert e["deleted_at"] is not None, f"edge {eid} lost its tombstone"
        assert e["updated_at"] >= e["deleted_at"] - 1.0

    untouched = _row("SELECT deleted_at FROM edges WHERE id = ?", g["e_untouched"])
    assert untouched["deleted_at"] is None, "an unrelated edge was tombstoned"


def test_delete_node_edge_tombstone_shares_the_node_transaction():
    """7.1: same transaction as the node write.

    Proven by failing the node write and asserting the edge write rolled back
    with it: if the two were separate transactions the edges would already be
    tombstoned while the node stayed live — every relation gone from a memory
    the user still has.
    """
    g = _tombstone_graph()
    real_tx = store._tx

    class _Boom(RuntimeError):
        pass

    import contextlib

    @contextlib.contextmanager
    def _exploding_tx():
        with real_tx() as tx:
            yield tx
            raise _Boom("simulated crash after the tombstone writes")

    with patch.object(store, "_tx", _exploding_tx):
        assert store.delete_node(g["ana"]) is False

    assert _row("SELECT deleted_at FROM nodes WHERE id = ?", g["ana"])["deleted_at"] is None
    assert _row(
        "SELECT deleted_at FROM edges WHERE id = ?", g["e_hub_ana"]
    )["deleted_at"] is None, "the edge tombstone survived a rolled-back node delete"


# ── 7.2 / 7.3 — FTS and vec rows stay HARD deletes, deliberately ──────────

def test_delete_node_hard_deletes_the_fts_row_and_must_not_tombstone_it():
    """7.2: `nodes_fts` is local derived state and is never synced.

    Pinned as a deliberate keep, not an oversight. Turning this into a
    tombstone fails here — and would also break the 7.11 invariant below.
    """
    g = _tombstone_graph()
    store.delete_node(g["ana"])

    remaining = store._connect().execute(
        "SELECT count(*) FROM nodes_fts WHERE rowid = ?", (g["ana"],)
    ).fetchone()[0]
    assert remaining == 0, "the FTS row survived; FTS rows must be hard-deleted"


def test_delete_node_hard_deletes_the_vec_row_and_must_not_tombstone_it():
    """7.3: `vec_nodes` is local derived state too — hard delete, best-effort.

    Also covers a consequence of PR7 that nothing else would notice:
    `trg_nodes_delete_vec` is an AFTER DELETE trigger, so it stops firing the
    moment the node delete becomes an UPDATE. The explicit statement in
    `delete_node` is now the only thing cleaning vec_nodes.
    """
    g = _tombstone_graph()
    c = store._connect()
    store.create_vec_nodes_table(c)
    store.upsert_vec_node(c, node_id=g["ana"], vector=[0.1] * 512)
    assert c.execute(
        "SELECT count(*) FROM vec_nodes WHERE node_id = ?", (g["ana"],)
    ).fetchone()[0] == 1

    store.delete_node(g["ana"])

    assert c.execute(
        "SELECT count(*) FROM vec_nodes WHERE node_id = ?", (g["ana"],)
    ).fetchone()[0] == 0, "the vec row survived; vec_nodes rows must be hard-deleted"


# ── 7.5 — delete_edge ─────────────────────────────────────────────────────

def test_delete_edge_tombstones_the_edge_row():
    """7.5: `delete_edge` marks instead of removing, and bumps `updated_at`."""
    g = _tombstone_graph()
    before = _row("SELECT updated_at FROM edges WHERE id = ?", g["e_hub_ana"])["updated_at"]
    time.sleep(0.01)

    assert store.delete_edge(g["e_hub_ana"]) is True

    e = _row("SELECT deleted_at, updated_at FROM edges WHERE id = ?", g["e_hub_ana"])
    assert e is not None, "the edge row was hard-deleted; a tombstone must survive"
    assert e["deleted_at"] is not None
    assert e["updated_at"] > before


def test_delete_edge_twice_reports_false_the_second_time():
    g = _tombstone_graph()
    assert store.delete_edge(g["e_hub_ana"]) is True
    assert store.delete_edge(g["e_hub_ana"]) is False


# ── 7.11 — THE FTS INVARIANT (the named worst case) ───────────────────────

def test_tombstoning_a_node_removes_its_fts_row_in_the_same_transaction():
    """7.11: search must not hand back a memory the graph says is deleted.

    Asserted directly on `nodes_fts` rather than through `search_nodes_fts`,
    so a later `deleted_at IS NULL` filter added on the read side cannot make
    this pass while the stale index row is still sitting there.
    """
    nid = store.add_node("fact", "un recuerdo que el usuario borra")
    assert store._connect().execute(
        "SELECT count(*) FROM nodes_fts WHERE rowid = ?", (nid,)
    ).fetchone()[0] == 1

    store.delete_node(nid)

    assert store._connect().execute(
        "SELECT count(*) FROM nodes_fts WHERE rowid = ?", (nid,)
    ).fetchone()[0] == 0, (
        "nodes_fts still carries the deleted node — search would return a "
        "memory the user deleted"
    )


def test_fts_invariant_holds_across_every_tombstoning_path():
    """No `nodes_fts` rowid may join a node carrying `deleted_at`.

    Stated as a whole-database invariant, not per call site, so a future
    tombstone path that forgets the FTS row is caught here rather than by the
    user searching for something they deleted.
    """
    g = _tombstone_graph()
    store.delete_node(g["ana"])
    store.delete_node(g["fact"])

    orphans = store._connect().execute(
        "SELECT f.rowid FROM nodes_fts f JOIN nodes n ON n.id = f.rowid "
        "WHERE n.deleted_at IS NOT NULL"
    ).fetchall()
    assert orphans == [], f"FTS rows survive for tombstoned nodes: {[r[0] for r in orphans]}"


def test_search_nodes_fts_cannot_return_a_tombstoned_node():
    """The user-facing half of 7.11, through the real search entry point."""
    store.add_node("fact", "Axi corre en CachyOS")
    doomed = store.add_node("fact", "Axi corre en Windows")
    assert len(store.search_nodes_fts("Axi")) == 2

    store.delete_node(doomed)

    hits = store.search_nodes_fts("Axi")
    assert [h["id"] for h in hits] == [
        h["id"] for h in hits if h["id"] != doomed
    ], "search returned a deleted memory"
    assert len(hits) == 1


# ── 7.9 — tombstoned rows are invisible to every read path ────────────────
#
# These tombstone the row DIRECTLY rather than going through `delete_node`.
# Two reasons, and the first is the one that matters:
#
#   1. Going through `delete_node` would let these tests pass against the
#      pre-PR7 hard delete for the wrong reason — the row is invisible because
#      it is gone, not because the read filters. They would then only break in
#      the exact half-applied state PR7 must never be left in (writes
#      tombstoning, reads not yet filtering), i.e. they would prove nothing
#      about the filter and would go RED at the worst possible moment.
#   2. A row tombstoned without a local delete is the shape sync produces: a
#      remote tombstone applied by the sync engine. The read filter is the
#      only thing standing between that and the memory reappearing.

def _tombstone_node(node_id: int) -> None:
    store._connect().execute(
        "UPDATE nodes SET deleted_at = ? WHERE id = ?", (time.time(), node_id)
    )


def _tombstone_edge(edge_id: int) -> None:
    store._connect().execute(
        "UPDATE edges SET deleted_at = ?, updated_at = ? WHERE id = ?",
        (time.time(), time.time(), edge_id),
    )


def test_get_node_does_not_return_a_tombstoned_node():
    g = _tombstone_graph()
    _tombstone_node(g["ana"])
    assert store.get_node(g["ana"]) is None


def test_neighbors_skips_a_tombstoned_neighbour_node():
    g = _tombstone_graph()
    assert {n["id"] for n in store.neighbors(g["hub"])} == {g["ana"], g["other"]}

    _tombstone_node(g["ana"])
    assert {n["id"] for n in store.neighbors(g["hub"])} == {g["other"]}


def test_neighbors_skips_an_edge_tombstoned_on_its_own():
    """A live node reached only through a deleted relation is not a neighbour."""
    g = _tombstone_graph()
    _tombstone_edge(g["e_untouched"])
    assert {n["id"] for n in store.neighbors(g["hub"])} == {g["ana"]}


def test_neighbors_with_an_edge_kind_filter_also_skips_tombstones():
    """The `edge_kind` branch is a separate SQL string and a separate risk."""
    g = _tombstone_graph()
    assert {n["id"] for n in store.neighbors(g["hub"], "esposa")} == {g["ana"]}
    _tombstone_edge(g["e_hub_ana"])
    assert store.neighbors(g["hub"], "esposa") == []


def test_same_day_neighbors_skips_tombstones_in_both_arms():
    a = store.add_node("fact", "desayuno")
    b = store.add_node("fact", "junta")
    d = store.add_node("fact", "cena")
    store.add_edge(a, b, "same-day")   # a is the src arm
    store.add_edge(d, a, "same-day")   # a is the dst arm
    assert {n["id"] for n in store.same_day_neighbors(a)} == {b, d}

    _tombstone_node(b)
    _tombstone_node(d)
    assert store.same_day_neighbors(a) == []


def test_same_day_neighbors_skips_a_tombstoned_edge_in_both_arms():
    a = store.add_node("fact", "desayuno")
    b = store.add_node("fact", "junta")
    d = store.add_node("fact", "cena")
    e1 = store.add_edge(a, b, "same-day")
    e2 = store.add_edge(d, a, "same-day")
    _tombstone_edge(e1)
    _tombstone_edge(e2)
    assert store.same_day_neighbors(a) == []


def test_recent_facts_skips_a_tombstoned_fact():
    live = store.add_node("fact", "presión 110/81")
    doomed = store.add_node("fact", "presión 200/120")
    assert {r["id"] for r in store.recent_facts()} == {live, doomed}

    _tombstone_node(doomed)
    assert {r["id"] for r in store.recent_facts()} == {live}


def test_find_fact_by_label_skips_a_tombstoned_fact():
    """A tombstoned duplicate must not block re-recording the same fact.

    If the dedup guard kept matching the deleted row, the user could delete a
    fact and then never be able to record it again — the graph would silently
    refuse and report nothing.
    """
    nid = store.add_node("fact", "toma losartán")
    assert store.find_fact_by_label("toma losartán") == nid
    _tombstone_node(nid)
    assert store.find_fact_by_label("toma losartán") is None


def test_search_nodes_fts_filters_a_node_tombstoned_without_a_local_delete():
    """The FTS invariant covers LOCAL deletes; this covers the sync shape.

    `delete_node` removes the `nodes_fts` row, so the invariant alone protects
    the local path. A tombstone arriving from a peer does not go through
    `delete_node`, and then only the read filter stops search from handing back
    a memory the user deleted on their phone.
    """
    store.add_node("fact", "Axi corre en CachyOS")
    doomed = store.add_node("fact", "Axi corre en Windows")
    _tombstone_node(doomed)

    assert [h["id"] for h in store.search_nodes_fts("Axi")] != [doomed]
    assert doomed not in {h["id"] for h in store.search_nodes_fts("Axi")}


def test_similar_to_guard_ignores_a_tombstoned_edge():
    """A tombstoned relation must not permanently block re-linking.

    The duplicate guard in `check_and_create_similar_to_edges` is a READ. If it
    kept seeing the tombstone, a deleted `similar-to` edge could never be
    re-derived, and nothing would say why.
    """
    a = store.add_node("fact", "vive en México")
    b = store.add_node("fact", "vive en Ciudad de México")
    eid = store.add_edge(a, b, "similar-to")
    _tombstone_edge(eid)

    c = store._connect()
    exists = c.execute(
        "SELECT 1 FROM edges WHERE "
        "src_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
        "dst_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
        "relation= 'similar-to' AND deleted_at IS NULL LIMIT 1",
        (a, b),
    ).fetchone()
    assert exists is None

    with patch.object(store, "knn_nodes_with_distance", lambda *a2, **k: [(b, 0.05)]), \
         patch.object(store, "_load_sqlite_vec", lambda *a2, **k: None):
        c.execute(
            "UPDATE nodes SET embedding = ?, embedding_dim = 512 WHERE id = ?",
            (struct.pack("512f", *([0.1] * 512)), a),
        )
        created = store.check_and_create_similar_to_edges(a, c)
    assert created == 1, "the tombstoned edge blocked re-linking"


def test_semantic_search_metadata_fetch_skips_tombstoned_nodes():
    """vec rows are hard-deleted, but the metadata fetch filters too.

    Defence in depth: `vec_nodes` cleanup is explicitly best-effort (it is
    wrapped in try/except because sqlite-vec may be unloaded), so a surviving
    vec row must not be able to resurface a deleted memory in recall.
    """
    live = store.add_node("fact", "vive en México")
    doomed = store.add_node("fact", "vive en Marte")
    _tombstone_node(doomed)

    c = store._connect()
    with patch.object(store, "embed_text", lambda *a, **k: [0.1] * 512), \
         patch.object(store, "knn_nodes_scored", lambda *a, **k: [(doomed, 0.1), (live, 0.2)]):
        out = store.semantic_search_nodes("vive", conn=c)

    assert [r["id"] for r in out] == [live]


# ── 7.14 — dangling edges: loud, report-only, never a hard failure ────────

def test_report_dangling_edges_reports_and_does_not_raise():
    """7.14: an endpoint uuid with no live node is LEGAL.

    Mobile's model allows an edge to sync before its node arrives, so this can
    never be a hard failure. It must still be visible: silently ignoring it is
    how a permanently broken link stops being anyone's problem.
    """
    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    eid = store.add_edge(hub, ana, "esposa")
    # Tombstone the NODE only, leaving the edge live. This is the shape sync
    # produces: a remote tombstone for the node applied before (or without)
    # the matching edge tombstone, or an edge that arrived before its node.
    store._connect().execute(
        "UPDATE nodes SET deleted_at = ? WHERE id = ?", (time.time(), ana)
    )

    report = store.report_dangling_edges()

    assert isinstance(report, list)
    assert len(report) == 1
    entry = report[0]
    assert f"id={eid}" in entry, f"the report does not name the offending edge: {entry!r}"
    assert "Row object" not in entry, "the report leaked a repr instead of values"
    assert "dst_uuid" in entry


def test_report_dangling_edges_is_empty_on_a_healthy_graph():
    _tombstone_graph()
    assert store.report_dangling_edges() == []


def test_report_dangling_edges_ignores_tombstoned_edges():
    """A tombstoned edge pointing at a tombstoned node is not a dangling edge.

    Both sides are deleted, which is a consistent state, not a broken link.
    Reporting it would bury the real cases in noise from every normal delete.
    """
    g = _tombstone_graph()
    store.delete_node(g["ana"])  # tombstones ana AND both of its edges
    assert store.report_dangling_edges() == []


def test_report_dangling_edges_raises_when_it_cannot_run():
    """LifeOS silent-failure rule: a check that cannot run fails loudly.

    Report-only applies to the FINDINGS, not to the check itself. A check that
    silently returns "nothing wrong" because it could not execute is the exact
    shape this codebase has already had to fix once.
    """
    class _BrokenConn:
        def execute(self, *a, **k):
            raise RuntimeError("no such table: edges")

    with pytest.raises(RuntimeError) as excinfo:
        store.report_dangling_edges(conn=_BrokenConn())
    assert "dangling-edge check could not run" in str(excinfo.value)


def test_init_db_actually_runs_the_dangling_edge_report(caplog):
    """7.14's check had no production caller — it passed its own tests and
    never ran once.

    After PR8 there is no ON DELETE CASCADE and no FK on the endpoints, so
    this report is the only thing looking at link integrity. Asserting that
    the FUNCTION works says nothing about whether anything calls it, which is
    exactly how it sat unwired through two phases.
    """
    hub = store.add_node("person", "Héctor")
    other = store.add_node("fact", "un dato")
    eid = store.add_edge(hub, other, "about")
    # An endpoint no live node answers to — legal per mobile's model (an edge
    # may sync before its node), which is why it is reported and not raised.
    store._connect().execute(
        "UPDATE edges SET dst_uuid='no-node-has-this-uuid' WHERE id=?", (eid,)
    )

    with caplog.at_level("ERROR"):
        store.init_db()

    assert any("dangling edge" in r.message for r in caplog.records), (
        "init_db did not report the dangling edge; the check is unwired again"
    )
    assert any(f"id={eid}" in r.getMessage() for r in caplog.records), (
        "the report does not name the offending edge"
    )


def test_a_broken_dangling_report_does_not_stop_the_daemon_starting(caplog):
    """The deliberate exception to this file's fail-loudly rule, pinned.

    PR8 nearly shipped the opposite shape: a guard that raises on "cannot run"
    is called from startup, so one stale join left the daemon refusing to boot
    on a database with no code-level revert. That guard protects a corruption
    invariant and keeps its teeth. This one reports link health — losing the
    report is bad, losing the daemon because the report broke is worse.
    """
    def _explode(*_a, **_kw):
        raise RuntimeError("simulated: the report cannot run")

    real = store.report_dangling_edges
    store.report_dangling_edges = _explode
    try:
        with caplog.at_level("ERROR"):
            store.init_db()          # must NOT raise
    finally:
        store.report_dangling_edges = real

    assert any("could not run" in r.getMessage() for r in caplog.records), (
        "the broken report failed silently; it must still be loud"
    )
