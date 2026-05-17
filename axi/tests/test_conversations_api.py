"""Tests for the conversation history endpoint (P1.4)."""
from __future__ import annotations

import time

from fastapi.testclient import TestClient

from axi import dashboard, store


def _client():
    return TestClient(dashboard.app)


def test_empty_store_returns_empty_list():
    r = _client().get("/api/conversations")
    assert r.status_code == 200
    assert r.json() == []


def test_pagination_with_before_ts():
    # Insert N turns with controlled ts.
    base = time.time() - 1000
    c = store._connect()
    for i in range(10):
        c.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, session_id, has_screenshot) "
            "VALUES (?, ?, ?, ?, 0)",
            (base + i, f"u{i}", f"a{i}", "s1"),
        )
    r = _client().get("/api/conversations?limit=5")
    assert r.status_code == 200
    page1 = r.json()
    assert len(page1) == 5
    # Newest first
    assert page1[0]["user_text"] == "u9"
    cutoff = page1[-1]["ts"]
    r2 = _client().get(f"/api/conversations?before_ts={cutoff}&limit=5")
    page2 = r2.json()
    assert len(page2) == 5
    assert page2[0]["user_text"] == "u4"


def test_since_ts_filter():
    base = time.time()
    c = store._connect()
    for i in range(5):
        c.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, has_screenshot) "
            "VALUES (?, ?, ?, 0)",
            (base + i, f"u{i}", f"a{i}"),
        )
    r = _client().get(f"/api/conversations?since_ts={base + 2}")
    assert r.status_code == 200
    data = r.json()
    assert {t["user_text"] for t in data} == {"u2", "u3", "u4"}


def test_fact_ids_populated_via_edges():
    # Build a conversation node and link two fact nodes to it via edges.
    conv_node = store.add_node(kind="conversation", label="turn-1")
    fact1 = store.add_node(kind="fact", label="hecho A")
    fact2 = store.add_node(kind="fact", label="hecho B")
    store.add_edge(conv_node, fact1, "mentioned_in")
    store.add_edge(conv_node, fact2, "mentioned_in")
    # Insert conversation row pointing at the node.
    c = store._connect()
    c.execute(
        "INSERT INTO conversations(ts, user_text, axi_text, has_screenshot, node_id) "
        "VALUES (?, ?, ?, 0, ?)",
        (time.time(), "pregunta", "respuesta", conv_node),
    )

    r = _client().get("/api/conversations")
    assert r.status_code == 200
    data = r.json()
    assert len(data) == 1
    assert sorted(data[0]["fact_ids"]) == sorted([fact1, fact2])


def test_limit_bounds():
    r = _client().get("/api/conversations?limit=0")
    assert r.status_code == 400
    r = _client().get("/api/conversations?limit=501")
    assert r.status_code == 400


def test_conversations_page_renders():
    r = _client().get("/conversations")
    assert r.status_code == 200
    assert "Conversaciones" in r.text
