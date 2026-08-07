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
    # PR7: deleted means tombstoned, not removed — sync cannot replicate an
    # absence, so a removed row comes back from the next peer that still has
    # it. The user-visible claim of this test (the node and its relations are
    # gone from the graph) is unchanged and is what is asserted here.
    assert conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE id = ? AND deleted_at IS NULL",
        (ids["person"],),
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT COUNT(*) FROM edges WHERE (src_uuid=(SELECT uuid FROM nodes WHERE id=?) OR dst_uuid=(SELECT uuid FROM nodes WHERE id=?)) "
        "AND deleted_at IS NULL",
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


# ── POST /api/graph/merge ────────────────────────────────────────────────────

def test_merge_folds_duplicate_into_canonical(client):
    """Happy path: a duplicate person is folded into the canonical survivor —
    its edge moves onto the survivor, the duplicate disappears, the alias is
    recorded, and the response shape is exact."""
    import json
    from axi import store

    canonical = store.add_node("person", "Ana Ríos", domain="relationships")
    dup = store.add_node("person", "Ani", domain="relationships")
    other = store.add_node("person", "Rodrigo", domain="relationships")
    # The edge lives on the DUPLICATE; after merge it must hang off the survivor.
    store.add_edge(dup, other, "amiga")

    r = client.post(
        "/api/graph/merge",
        json={"canonical_id": canonical, "duplicate_id": dup},
    )
    assert r.status_code == 200
    assert r.json() == {
        "merged": True,
        "survivor_id": canonical,
        "absorbed_id": dup,
    }

    conn = store._connect()  # noqa: SLF001
    # Duplicate no longer live, survivor kept. PR7: a merge is a delete, and
    # every node delete is now a tombstone — the row stays on disk carrying
    # `deleted_at` so the merge can be replicated instead of the duplicate
    # being pushed back by the next peer that still has it.
    assert conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE id = ? AND deleted_at IS NULL", (dup,)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT deleted_at FROM nodes WHERE id = ?", (dup,)
    ).fetchone()["deleted_at"] is not None
    assert conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE id = ?", (canonical,)
    ).fetchone()[0] == 1
    # The edge was repointed onto the survivor.
    edge = conn.execute(
        "SELECT (SELECT id FROM nodes WHERE uuid = edges.src_uuid) AS from_id, "
        "       (SELECT id FROM nodes WHERE uuid = edges.dst_uuid) AS to_id "
        "FROM edges WHERE relation = 'amiga'"
    ).fetchone()
    assert edge["from_id"] == canonical
    assert edge["to_id"] == other
    # The absorbed label is recorded as an alias on the survivor.
    data = json.loads(
        conn.execute("SELECT data FROM nodes WHERE id = ?", (canonical,)).fetchone()["data"] or "{}"
    )
    assert "Ani" in data.get("aliases", [])


def test_merge_refuses_kind_mismatch(client):
    from axi import store
    a = store.add_node("person", "Alpha")
    b = store.add_node("place", "Beta")
    r = client.post("/api/graph/merge", json={"canonical_id": a, "duplicate_id": b})
    assert r.status_code == 400
    assert r.json() == {"merged": False, "reason": "kind_mismatch"}


def test_merge_refuses_hub(client):
    from axi import store
    hub = store.add_node("person", "Héctor", data={"role": "user"})
    other = store.add_node("person", "Rodrigo")
    r = client.post("/api/graph/merge", json={"canonical_id": other, "duplicate_id": hub})
    assert r.status_code == 400
    assert r.json() == {"merged": False, "reason": "hub"}


def test_merge_refuses_conversation(client):
    from axi import store
    a = store.add_node("person", "Alpha")
    conv = store.add_node("conversation", "charla")
    r = client.post("/api/graph/merge", json={"canonical_id": a, "duplicate_id": conv})
    assert r.status_code == 400
    assert r.json() == {"merged": False, "reason": "conversation"}


def test_merge_refuses_same_id(client):
    from axi import store
    a = store.add_node("person", "Alpha")
    r = client.post("/api/graph/merge", json={"canonical_id": a, "duplicate_id": a})
    assert r.status_code == 400
    assert r.json() == {"merged": False, "reason": "same_id"}


def test_merge_unknown_404(client):
    from axi import store
    a = store.add_node("person", "Alpha")
    r = client.post("/api/graph/merge", json={"canonical_id": a, "duplicate_id": 999999})
    assert r.status_code == 404


# ── /api/graph/full: created_at for date filters ─────────────────────────────

def test_graph_full_includes_created_at(client):
    """Date filters need created_at on every node — the endpoint must expose it."""
    from axi import store
    store.add_node("fact", "hecho con fecha", domain="health")
    r = client.get("/api/graph/full")
    assert r.status_code == 200
    nodes = r.json()["nodes"]
    assert len(nodes) >= 1
    assert "created_at" in nodes[0]
    assert nodes[0]["created_at"] is not None


# ── legacy 2D endpoint retired ───────────────────────────────────────────────

def test_legacy_graph_endpoint_gone(client):
    """The legacy /api/graph (2D cytoscape) endpoint was removed in Stage 2."""
    assert client.get("/api/graph").status_code == 404


# ── Stage 3: relations payload carries edge_id ───────────────────────────────

def test_node_detail_relations_include_edge_id(client):
    """Each typed relation now carries its edge_id so the UI can forget it."""
    from axi import store
    a = store.add_node("person", "Ana", domain="relationships")
    b = store.add_node("person", "Beto", domain="relationships")
    edge_id = store.add_edge(a, b, "amigo")

    body = client.get(f"/api/graph/node/{a}").json()
    assert len(body["relations"]) == 1
    rel = body["relations"][0]
    assert rel["kind"] == "amigo"
    assert rel["edge_id"] == edge_id


# ── Stage 3: DELETE /api/graph/edge/{id} (forget a relationship) ──────────────

def test_delete_edge_removes_only_edge(client):
    """Forgetting an edge removes the edge but keeps BOTH endpoint nodes."""
    from axi import store
    a = store.add_node("person", "Uno", domain="relationships")
    b = store.add_node("person", "Dos", domain="relationships")
    edge_id = store.add_edge(a, b, "conoce")

    r = client.delete(f"/api/graph/edge/{edge_id}")
    assert r.status_code == 200
    assert r.json() == {"deleted": True}

    conn = store._connect()  # noqa: SLF001
    # PR7: tombstoned, not removed. The claim under test — the relation is gone
    # and both people are not — is unchanged.
    assert conn.execute(
        "SELECT COUNT(*) FROM edges WHERE id = ? AND deleted_at IS NULL", (edge_id,)
    ).fetchone()[0] == 0
    # Both endpoint nodes survive.
    assert conn.execute("SELECT COUNT(*) FROM nodes WHERE id = ?", (a,)).fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM nodes WHERE id = ?", (b,)).fetchone()[0] == 1


def test_delete_edge_unknown_404(client):
    assert client.delete("/api/graph/edge/999999").status_code == 404


# ── Stage 3: GET /api/graph/node/{id}/neighborhood (navigate outside load) ────

def test_neighborhood_returns_node_and_neighbors(client):
    from axi import store
    center = store.add_node("person", "Centro", domain="relationships")
    n1 = store.add_node("person", "Vecino1", domain="relationships")
    n2 = store.add_node("fact", "un hecho", domain="relationships")
    e1 = store.add_edge(center, n1, "amigo")
    e2 = store.add_edge(n2, center, "mentions")

    body = client.get(f"/api/graph/node/{center}/neighborhood").json()
    ids = {n["id"] for n in body["nodes"]}
    assert ids == {center, n1, n2}
    assert body["truncated"] is False
    edge_ids = {e["id"] for e in body["edges"]}
    assert edge_ids == {e1, e2}
    # Node shape carries what the client injector needs.
    node = next(n for n in body["nodes"] if n["id"] == center)
    for key in ("id", "label", "kind", "domain", "created_at", "occurred_at", "has_embedding"):
        assert key in node


def test_neighborhood_truncates_over_cap(client, monkeypatch):
    from axi import dashboard, store
    monkeypatch.setattr(dashboard, "_NEIGHBORHOOD_CAP", 2)
    center = store.add_node("person", "Hub", domain="relationships")
    for i in range(3):
        nb = store.add_node("person", f"N{i}", domain="relationships")
        store.add_edge(center, nb, "conoce")

    body = client.get(f"/api/graph/node/{center}/neighborhood").json()
    assert body["truncated"] is True
    # center + at most cap neighbors.
    assert len(body["nodes"]) == 3
    # Only edges whose both endpoints are in the returned set are included.
    in_set = {n["id"] for n in body["nodes"]}
    for e in body["edges"]:
        assert e["source"] in in_set and e["target"] in in_set


def test_neighborhood_unknown_404(client):
    assert client.get("/api/graph/node/999999/neighborhood").status_code == 404


# ── Stage 3: brain3d.html markers (edge forget, merge undo, navigate, i18n) ───

def test_brain3d_stage3_markers(client):
    html = client.get("/brain3d").text
    # Edge-forget affordance (Spanish title) + handler.
    assert "Olvidar esta relación" in html
    assert "forgetRelation" in html
    assert "/api/graph/edge/" in html
    # Generic undo machinery + bar still present.
    assert "_startPending" in html
    assert 'id="undo-bar"' in html
    # Merge-undo message marker (deferred merge rides the undo window).
    assert "Fusionado '" in html
    assert "Fusión deshecha." in html
    # Navigate-outside-load: neighborhood injection.
    assert "_injectNeighborhood" in html
    assert "/neighborhood" in html


def test_brain3d_stage3_i18n_both_locales(client):
    html = client.get("/brain3d").text
    for es in ["Olvidar esta relación", "Relación olvidada.", "Fusión deshecha.",
               "Mostrando parte de su vecindario."]:
        assert es in html, f"missing es string: {es}"
    for en in ["Forget this relationship", "Relationship forgotten.", "Merge undone.",
               "Showing part of its neighborhood."]:
        assert en in html, f"missing en string: {en}"


# ── brain3d.html Stage-2 markers (merge, filters, novedades, i18n) ───────────

def test_brain3d_stage2_markers(client):
    html = client.get("/brain3d").text
    # Merge affordance + confirm control.
    assert "Fusionar" in html
    assert 'id="merge-node-btn"' in html
    assert 'id="confirm-merge-btn"' in html
    # Novedades de la semana quick view.
    assert "Novedades de la semana" in html
    assert 'id="new-week-btn"' in html
    assert 'id="new-week-panel"' in html
    # Interactive domain legend.
    assert "toggleDomain" in html
    # Date filter presets (Spanish).
    assert "Esta semana" in html


def test_brain3d_stage2_i18n_both_locales(client):
    """The new keys exist in BOTH es and en maps; es values are Spanish."""
    html = client.get("/brain3d").text
    # Spanish (es — the live default).
    for es in ["Fusionar con…", "Novedades de la semana", "Esta semana",
               "Se conservará:", "Solo se pueden fusionar nodos del mismo tipo."]:
        assert es in html, f"missing es string: {es}"
    # English counterparts — proves the same keys exist in the en map too.
    for en in ["Merge with…", "This week", "Will be kept:",
               "You can only merge nodes of the same kind."]:
        assert en in html, f"missing en string: {en}"


# ── /api/graph/full aliases + brain3d alias-aware search ─────────────────────
def test_graph_full_exposes_node_aliases(client):
    """A node whose data carries aliases surfaces them in /api/graph/full; a node
    with no aliases yields []."""
    from axi import store

    with_aliases = store.add_node(
        "person", "Ana Ríos",
        data={"aliases": ["Ani", "Ana Rios"]}, domain="relationships",
    )
    without = store.add_node("person", "Rodrigo", domain="relationships")

    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    by_id = {n["id"]: n for n in resp.json()["nodes"]}

    assert by_id[with_aliases]["aliases"] == ["Ani", "Ana Rios"]
    # No aliases key in data → empty list, never missing/None.
    assert by_id[without]["aliases"] == []


def test_graph_full_aliases_malformed_data_is_safe(client):
    """A node whose data column is not valid JSON must not crash the endpoint and
    must fall back to an empty aliases list."""
    from axi import store

    node_id = store.add_node("person", "Broken", domain="relationships")
    conn = store._connect()  # noqa: SLF001
    conn.execute("UPDATE nodes SET data = ? WHERE id = ?", ("{not json", node_id))
    conn.commit()

    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    by_id = {n["id"]: n for n in resp.json()["nodes"]}
    assert by_id[node_id]["aliases"] == []


def test_brain3d_alias_aware_search_markers(client):
    """The client search now matches aliases and ranks entity kinds above blobs."""
    html = client.get("/brain3d").text
    # Node objects carry aliases from the payload into the in-memory graph.
    assert "aliases: n.aliases" in html
    # Entity-vs-blob ranking marker (the named constant the ranking relies on).
    assert "_ENTITY_KINDS" in html
    # searchInput scores/ranks rather than doing a bare label substring match.
    assert "aliasScore" in html
    assert "isEntityKind" in html


# ── /api/graph/search — server-side search over the FULL node table ──────────

def test_graph_search_finds_fts_and_alias_hits(client):
    """Search returns a node matched only via FTS AND one matched only via the
    alias LIKE fallback; conversation nodes are excluded."""
    from axi import store

    # Matched via FTS (a token in the label): "Querétaro".
    fact = store.add_node("fact", "Rodrigo vive en Querétaro", domain="relationships")
    # Matched only via alias LIKE fallback: label doesn't contain "ani",
    # the alias does. (FTS would also index the alias, but this proves aliases
    # are searchable regardless of the pass.)
    person = store.add_node(
        "person", "Ana Ríos",
        data={"aliases": ["Ani"]}, domain="relationships",
    )
    # Must be excluded even though its label contains the query term.
    store.add_node("conversation", "charla sobre Querétaro y Ani")

    r = client.get("/api/graph/search", params={"q": "queretaro"})
    assert r.status_code == 200
    assert fact in [n["id"] for n in r.json()]

    r2 = client.get("/api/graph/search", params={"q": "ani"})
    ids2 = [n["id"] for n in r2.json()]
    assert person in ids2
    # No conversation node ever surfaces.
    kinds = [n["kind"] for n in r2.json()]
    assert "conversation" not in kinds


def test_graph_search_result_shape_includes_aliases(client):
    from axi import store

    pid = store.add_node(
        "person", "Ana Ríos",
        data={"aliases": ["Ani", "Ana Rios"]}, domain="relationships",
    )
    rows = client.get("/api/graph/search", params={"q": "ana"}).json()
    hit = next(n for n in rows if n["id"] == pid)
    assert set(hit.keys()) == {"id", "label", "kind", "domain", "aliases"}
    assert hit["aliases"] == ["Ani", "Ana Rios"]
    assert hit["domain"] == "relationships"


def test_graph_search_entity_ranked_above_fact(client):
    """When both an entity and a fact match, the entity kind ranks first."""
    from axi import store

    store.add_node("fact", "Nota sobre Celaya", domain="relationships")
    person = store.add_node("person", "Celaya López", domain="relationships")

    rows = client.get("/api/graph/search", params={"q": "celaya"}).json()
    assert rows[0]["id"] == person
    assert rows[0]["kind"] == "person"


def test_graph_search_accent_insensitive(client):
    """A query WITHOUT accents finds an accented label (FTS remove_diacritics)."""
    from axi import store

    pid = store.add_node("person", "José Ramírez", domain="relationships")
    rows = client.get("/api/graph/search", params={"q": "jose ramirez"}).json()
    assert pid in [n["id"] for n in rows]


def test_graph_search_internal_substring_via_like_fallback(client):
    """A mid-word substring FTS's token-prefix match misses is caught by the
    normalized LIKE fallback (and it stays accent-insensitive)."""
    from axi import store

    pid = store.add_node("person", "José Ramírez", domain="relationships")
    # "amire" is inside "Ramirez" (normalized), not a token prefix → FTS misses.
    rows = client.get("/api/graph/search", params={"q": "amire"}).json()
    assert pid in [n["id"] for n in rows]


def test_graph_search_blank_query_returns_empty(client):
    from axi import store

    store.add_node("person", "Rodrigo", domain="relationships")
    assert client.get("/api/graph/search", params={"q": ""}).json() == []
    assert client.get("/api/graph/search", params={"q": "   "}).json() == []


def test_graph_search_limit_respected_and_capped(client):
    from axi import store

    for i in range(8):
        store.add_node("person", f"Testperson {i}", domain="relationships")

    rows = client.get("/api/graph/search", params={"q": "testperson", "limit": 3}).json()
    assert len(rows) == 3

    # Hard cap: limit above 50 is clamped (no crash, no over-return).
    capped = client.get("/api/graph/search", params={"q": "testperson", "limit": 999}).json()
    assert len(capped) <= 50


def test_graph_search_no_match_returns_empty(client):
    from axi import store

    store.add_node("person", "Rodrigo", domain="relationships")
    assert client.get("/api/graph/search", params={"q": "zzznomatch"}).json() == []


# ── brain3d.html server-search markers + i18n (both locales) ─────────────────

def test_brain3d_server_search_markers(client):
    """The client wires the server search: fetch, debounce, stale guard, merge,
    and navigateTo for out-of-view results."""
    html = client.get("/brain3d").text
    assert "/api/graph/search?q=" in html          # server endpoint call
    assert "_serverSearch" in html                  # merge routine
    assert "_searchDebounce" in html                # ~200ms debounce
    assert "_searchSeq" in html                     # stale-response guard
    assert "remote: true" in html                   # server-only rows flagged
    assert "await this.navigateTo(r.id)" in html    # click injects neighborhood


def test_brain3d_server_search_i18n_both_locales(client):
    html = client.get("/brain3d").text
    assert "tUi('notLoaded')" in html               # marker rendered from i18n
    assert "'fuera de vista'" in html               # es
    assert "'not loaded'" in html                   # en
