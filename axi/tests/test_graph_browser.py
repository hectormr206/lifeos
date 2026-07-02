"""Tests for the Stage-1 knowledge-graph browser (/brain3d).

Covers:
  - GET  /api/graph/node/{id} — detail payload (node, facts, relations,
    conversations) with structural-edge filtering and direction handling.
  - DELETE /api/graph/node/{id} — forget flow, hub/conversation refusals.
  - /graph retirement: 301 redirect, nav pointing at /brain3d, template gone.
  - brain3d.html Stage-1 markers: search box, focus chip, detail panel, forget.

TestClient style of test_nav_redesign.py; graph data seeded through
store.add_node/add_edge against the per-test DB (conftest fresh_db).
"""
from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

TEMPLATES_DIR = Path(__file__).parent.parent / "src" / "axi" / "templates"


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    return TestClient(dashboard.app)


def _seed_person_graph():
    """Seed: hub, a person with a typed edge, a fact via mentions, and
    conversation provenance. Returns the ids dict."""
    from axi import store

    hub = store.add_node("person", "Héctor", data={"role": "user"}, domain="relationships")
    person = store.add_node("person", "Rodrigo", domain="relationships")
    fact = store.add_node("fact", "Rodrigo vive en Querétaro", domain="relationships")
    conv_node = store.add_node("conversation", "charla sobre Rodrigo")

    # Typed human relation: Héctor —primo→ Rodrigo
    store.add_edge(hub, person, "primo")
    # Fact linked to the entity via mentions, and to the hub via about.
    store.add_edge(fact, person, "mentions")
    store.add_edge(fact, hub, "about")
    # Provenance: fact mentioned_in the conversation node.
    store.add_edge(fact, conv_node, "mentioned_in")

    # Conversation row bridged to the conversation node.
    conv_id = store.add_conversation("cuéntame de Rodrigo", "Rodrigo es tu primo")
    store.set_conversation_node_id(conv_id, conv_node)

    return {"hub": hub, "person": person, "fact": fact,
            "conv_node": conv_node, "conv_id": conv_id}


# ── GET /api/graph/node/{id} ─────────────────────────────────────────────────

def test_node_detail_shape_and_relations(client):
    ids = _seed_person_graph()
    r = client.get(f"/api/graph/node/{ids['person']}")
    assert r.status_code == 200
    body = r.json()

    # Node envelope
    node = body["node"]
    assert node["id"] == ids["person"]
    assert node["kind"] == "person"
    assert node["label"] == "Rodrigo"
    assert node["domain"] == "relationships"
    assert "created_at" in node and "occurred_at" in node and "data" in node

    # Relations: only the typed 'primo' edge (mentions is structural), inbound.
    assert len(body["relations"]) == 1
    rel = body["relations"][0]
    assert rel["kind"] == "primo"
    assert rel["direction"] == "in"          # hub —primo→ person
    assert rel["other_id"] == ids["hub"]
    assert rel["other_label"] == "Héctor"
    assert rel["other_kind"] == "person"

    # Facts: connected via mentions (fact → person).
    assert [f["id"] for f in body["facts"]] == [ids["fact"]]
    assert body["facts"][0]["label"] == "Rodrigo vive en Querétaro"
    assert "created_at" in body["facts"][0]


def test_node_detail_hub_direction_out(client):
    ids = _seed_person_graph()
    r = client.get(f"/api/graph/node/{ids['hub']}")
    assert r.status_code == 200
    body = r.json()
    rel = next(x for x in body["relations"] if x["kind"] == "primo")
    assert rel["direction"] == "out"         # hub —primo→ person
    assert rel["other_id"] == ids["person"]
    # Hub sees the fact through its 'about' edge.
    assert [f["id"] for f in body["facts"]] == [ids["fact"]]


def test_node_detail_conversation_provenance(client):
    ids = _seed_person_graph()
    r = client.get(f"/api/graph/node/{ids['fact']}")
    assert r.status_code == 200
    body = r.json()
    convs = body["conversations"]
    assert len(convs) == 1
    assert convs[0]["id"] == ids["conv_id"]
    assert convs[0]["user_text_snippet"] == "cuéntame de Rodrigo"
    assert "ts" in convs[0]
    # mentions/about/mentioned_in are structural — never listed as relations.
    assert body["relations"] == []


def test_node_detail_provenance_best_effort_empty(client):
    """A mentioned_in edge whose conversation node has no conversations row
    resolves to [] instead of failing."""
    from axi import store
    fact = store.add_node("fact", "hecho suelto")
    conv_node = store.add_node("conversation", "sin fila")
    store.add_edge(fact, conv_node, "mentioned_in")
    r = client.get(f"/api/graph/node/{fact}")
    assert r.status_code == 200
    assert r.json()["conversations"] == []


def test_node_detail_unknown_404(client):
    assert client.get("/api/graph/node/999999").status_code == 404


# ── DELETE /api/graph/node/{id} ──────────────────────────────────────────────

def test_delete_normal_node_removes_edges(client):
    from axi import store
    ids = _seed_person_graph()
    r = client.delete(f"/api/graph/node/{ids['person']}")
    assert r.status_code == 200
    assert r.json() == {"deleted": True}
    conn = store._connect()  # noqa: SLF001
    assert conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE id = ?", (ids["person"],)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT COUNT(*) FROM edges WHERE from_id = ? OR to_id = ?",
        (ids["person"], ids["person"]),
    ).fetchone()[0] == 0


def test_delete_refuses_hub(client):
    from axi import store
    ids = _seed_person_graph()
    r = client.delete(f"/api/graph/node/{ids['hub']}")
    assert r.status_code == 400
    assert r.json() == {"deleted": False, "reason": "hub"}
    conn = store._connect()  # noqa: SLF001
    assert conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE id = ?", (ids["hub"],)
    ).fetchone()[0] == 1


def test_delete_refuses_conversation_node(client):
    ids = _seed_person_graph()
    r = client.delete(f"/api/graph/node/{ids['conv_node']}")
    assert r.status_code == 400
    assert r.json() == {"deleted": False, "reason": "conversation"}


def test_delete_unknown_404(client):
    assert client.delete("/api/graph/node/999999").status_code == 404


# ── /graph retirement ────────────────────────────────────────────────────────

def test_graph_redirects_to_brain3d(client):
    r = client.get("/graph", follow_redirects=False)
    assert r.status_code == 301
    assert r.headers["location"] == "/brain3d"


def test_nav_points_to_brain3d(client):
    html = client.get("/").text
    assert 'href="/brain3d"' in html
    assert 'href="/graph"' not in html


def test_graph_template_deleted():
    assert not (TEMPLATES_DIR / "graph.html").exists()


# ── brain3d.html Stage-1 markers ─────────────────────────────────────────────

def test_brain3d_renders_browser_features(client):
    r = client.get("/brain3d")
    assert r.status_code == 200
    html = r.text
    # Search box + focus mode
    assert 'id="graph-search"' in html
    assert "Enfocado en:" in html
    assert "Buscar en tu memoria" in html
    # Detail panel sections
    assert 'id="node-sidebar"' in html
    assert "Relaciones" in html
    assert "Hechos" in html
    assert "Procedencia" in html
    # Forget flow (Spanish confirm + button)
    assert 'id="forget-node-btn"' in html
    assert "Olvidar este nodo" in html
    # Data still flows from the single full-graph load + on-demand detail API.
    assert "/api/graph/full" in html
    assert "/api/graph/node/" in html


def test_brain3d_focus_highlight_markers(client):
    """Focus mode recolors by relevance: teal focused node + dim-gray context,
    plus a Spanish legend hint."""
    html = client.get("/brain3d").text
    # Relevance-recolor overlay constants override the domain palette in focus.
    assert "FOCUS_TEAL" in html
    assert "FOCUS_DIM" in html
    assert "#3a4048" in html          # dim gray for 2nd-hop context
    # Spanish focus legend hint (teal = enfocado, gris = contexto).
    assert "teal = enfocado, gris = contexto" in html


def test_brain3d_undo_window_markers(client):
    """Deferred-delete + undo grace window replaces the immediate hard delete."""
    html = client.get("/brain3d").text
    # New safety-reflecting confirm message.
    assert "Podrás deshacerlo" in html
    # The old "cannot be undone" copy is gone — it is no longer true.
    assert "no se puede deshacer" not in html
    assert "Esta acción no se puede deshacer" not in html
    # Undo control + persistent bar.
    assert 'id="undo-delete-btn"' in html
    assert 'id="undo-bar"' in html
    assert "Deshacer" in html
    assert "Recuperado." in html
