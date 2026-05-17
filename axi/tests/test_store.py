"""Tests for the SQLite-backed knowledge store."""
from __future__ import annotations

import time

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
