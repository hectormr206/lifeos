"""Endpoint tests for the FastAPI dashboard.

The daemon socket and llama-server health probes are stubbed — these tests
only exercise the surface that depends on our own SQLite store + templates,
so they run in <1 s without spinning up the rest of the stack.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard, store

    # Force a fresh DB connection (the autouse conftest fixture has already
    # pointed store.DB_PATH at a temp file and run init_db()).
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

    return TestClient(dashboard.app)


def test_home_renders(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "Axi" in r.text


def test_snapshot_shape(client):
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    for key in ("now", "state", "services", "vram", "ram", "cpu_pct",
                "memory", "recent_conversations", "recent_facts"):
        assert key in data
    assert "iso" in data["now"]
    assert "tz" in data["now"]


def test_snapshot_state_falls_back_when_daemon_unreachable(client, monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "")
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["state"] == "unknown"


def test_facts_endpoint_empty(client):
    r = client.get("/api/facts")
    assert r.status_code == 200
    assert r.json() == []


def test_facts_endpoint_with_data(client):
    from axi import store
    store.add_node("fact", "Héctor usa HyperX SoloCast", {"category": "preference"}, domain="setup")
    r = client.get("/api/facts")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 1
    assert rows[0]["label"] == "Héctor usa HyperX SoloCast"
    assert rows[0]["domain"] == "setup"


def test_search_endpoint(client):
    from axi import store
    store.add_node("fact", "café favorito es americano", domain="setup")
    r = client.get("/api/search?q=café")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 1


def test_search_empty_query_returns_empty(client):
    r = client.get("/api/search?q=")
    assert r.status_code == 200
    assert r.json() == []


def test_cmd_rejects_unknown_command(client):
    r = client.post("/api/cmd/explode")
    assert r.status_code == 400


def test_cmd_accepts_known_command(client):
    r = client.post("/api/cmd/toggle")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_meetings_list_empty(client):
    r = client.get("/api/meetings")
    assert r.status_code == 200
    assert r.json() == []


def test_meeting_detail_404(client):
    r = client.get("/api/meetings/999")
    assert r.status_code == 404


def test_config_roundtrip(client, tmp_path, monkeypatch):
    from axi import config
    config_path = tmp_path / "config.json"
    monkeypatch.setattr(config, "CONFIG_PATH", config_path)
    monkeypatch.setattr(config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(config, "_cache", None)

    r = client.post("/api/config", json={"timezone": "Europe/Madrid"})
    assert r.status_code == 200
    assert r.json()["config"]["timezone"] == "Europe/Madrid"

    r = client.get("/api/config")
    assert r.json()["timezone"] == "Europe/Madrid"


def test_graph_endpoint_returns_cytoscape_shape(client):
    from axi import store
    a = store.add_node("fact", "fact A", domain="setup")
    b = store.add_node("person", "Héctor")
    store.add_edge(a, b, "belongs_to")
    r = client.get("/api/graph")
    assert r.status_code == 200
    data = r.json()
    assert "nodes" in data
    assert "edges" in data
    assert len(data["nodes"]) == 2
    # The single edge connects two visible nodes → must come through.
    assert len(data["edges"]) == 1
    assert data["edges"][0]["data"]["kind"] == "belongs_to"


def test_graph_excludes_conversation_nodes(client):
    from axi import store
    store.add_node("conversation", "old chat turn")
    store.add_node("fact", "real fact")
    r = client.get("/api/graph")
    data = r.json()
    assert len(data["nodes"]) == 1
    assert data["nodes"][0]["data"]["kind"] == "fact"
