"""Tests for Slice 4a/4b/4c — vendored JS, sw.js, brain3d route, graph.html.

RED phase first (tasks 4.2, 4.4, 4.6, 4.8, 4.10, 4.16).
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# ── helpers ────────────────────────────────────────────────────────────────

VENDOR_DIR = Path(__file__).parent.parent / "src" / "axi" / "static" / "vendor"
STATIC_DIR = Path(__file__).parent.parent / "src" / "axi" / "static"
TEMPLATES_DIR = Path(__file__).parent.parent / "src" / "axi" / "templates"


# ── /graph retired — the old 2D Cytoscape viewer redirects to /brain3d ──────

def test_graph_html_template_removed():
    """graph.html was retired with the /graph → /brain3d redirect."""
    assert not (TEMPLATES_DIR / "graph.html").exists()


# ── 4.4 — sw.js CACHE_VERSION bumped and new vendor files in precache ────────

def test_sw_cache_version_bumped():
    """sw.js declares a versioned CACHE_VERSION (axi-shell-v<N>).

    Version-agnostic on purpose: hardcoding a specific number (originally
    'axi-shell-v10') broke this test on every legitimate cache bump. We only
    care that a numbered shell-cache version exists.
    """
    import re
    sw_content = (STATIC_DIR / "sw.js").read_text()
    assert re.search(r"CACHE_VERSION\s*=\s*['\"]axi-shell-v\d+['\"]", sw_content), (
        "sw.js must declare a numbered CACHE_VERSION like axi-shell-v11"
    )


def test_sw_precache_includes_3d_force_graph():
    """Task 4.5 RED: sw.js precache list includes /static/vendor/3d-force-graph.min.js."""
    sw_content = (STATIC_DIR / "sw.js").read_text()
    assert "/static/vendor/3d-force-graph.min.js" in sw_content


def test_sw_precache_excludes_cytoscape():
    """cytoscape left the shell precache when graph.html was retired."""
    sw_content = (STATIC_DIR / "sw.js").read_text()
    assert "/static/vendor/cytoscape.min.js" not in sw_content


# ── vendor files exist on disk ───────────────────────────────────────────────

def test_vendor_3d_force_graph_exists():
    """3d-force-graph.min.js must be present in static/vendor."""
    assert (VENDOR_DIR / "3d-force-graph.min.js").exists()


def test_vendor_cytoscape_exists():
    """cytoscape.min.js must be present in static/vendor."""
    assert (VENDOR_DIR / "cytoscape.min.js").exists()


# ── 4.6 — GET /brain3d returns 200 ─────────────────────────────────────────

def test_brain3d_route_returns_200():
    """Task 4.6 RED: GET /brain3d returns HTTP 200."""
    from axi.dashboard import app
    client = TestClient(app)
    resp = client.get("/brain3d")
    assert resp.status_code == 200


def test_brain3d_returns_html():
    """GET /brain3d returns text/html content."""
    from axi.dashboard import app
    client = TestClient(app)
    resp = client.get("/brain3d")
    assert "text/html" in resp.headers.get("content-type", "")


# ── 4.8 — dashboard.html #organ-brain click opens brain3d modal ─────────────

def test_dashboard_organ_brain_wired_to_brain3d():
    """Task 4.8 RED: #organ-brain click handler in dashboard.html references brain3d."""
    dashboard_html = (TEMPLATES_DIR / "dashboard.html").read_text()
    # The organ-brain click must reference the brain3d modal (not just the old popover).
    assert "brain3d" in dashboard_html


def test_dashboard_brain3d_modal_present():
    """Task 4.8: dashboard.html contains the brain3d modal element."""
    dashboard_html = (TEMPLATES_DIR / "dashboard.html").read_text()
    assert "id=\"brain3d-modal\"" in dashboard_html or 'id="brain3d-modal"' in dashboard_html


# ── 4.10 — brain3d.html domain-color map present ────────────────────────────

def test_brain3d_template_has_domain_color_map():
    """Task 4.10 RED: brain3d.html includes a DOMAIN_COLOR map."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    assert "DOMAIN_COLOR" in brain3d_html
    # Must cover at least 5 known domains.
    for domain in ["relationships", "health", "finance", "conversation", "fact"]:
        assert domain in brain3d_html


def test_brain3d_template_references_3d_force_graph():
    """brain3d.html uses /static/vendor/3d-force-graph.min.js (no CDN)."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    assert "/static/vendor/3d-force-graph.min.js" in brain3d_html
    # Ensure no CDN reference for 3d-force-graph.
    assert "cdn.jsdelivr.net/npm/3d-force-graph" not in brain3d_html
    assert "unpkg.com/3d-force-graph" not in brain3d_html


# ── 4.16 — /api/graph/full empty-state shape (data contract) ─────────────────

def test_api_graph_full_returns_expected_shape_when_empty():
    """Task 4.16 RED: /api/graph/full returns {nodes:[], edges:[], partial:false} when empty."""
    from axi.dashboard import app
    import axi.store as store

    conn = store._connect()
    count = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    assert count == 0  # fresh_db ensures this

    client = TestClient(app)
    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    body = resp.json()
    assert body["nodes"] == []
    assert body["edges"] == []
    assert body.get("partial") is False


def test_api_graph_full_node_shape():
    """Data contract: every node has id, label, kind, domain, has_embedding."""
    from axi.dashboard import app
    import axi.store as store
    import time

    conn = store._connect()
    now = time.time()
    conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", "Contract test node", "{}", "health", now, now),
    )
    conn.commit()

    client = TestClient(app)
    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["nodes"]) >= 1
    node = body["nodes"][0]
    for field in ("id", "label", "kind", "domain", "has_embedding"):
        assert field in node, f"Missing field: {field}"


def test_api_graph_full_edge_shape():
    """Data contract: every edge has source, target, kind, system."""
    from axi.dashboard import app
    import axi.store as store
    import time

    conn = store._connect()
    now = time.time()
    c1 = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", "Edge node A", "{}", "health", now, now),
    )
    n1 = c1.lastrowid
    c2 = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", "Edge node B", "{}", "health", now, now),
    )
    n2 = c2.lastrowid
    conn.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at) VALUES (?, ?, ?, ?, ?)",
        (n1, n2, "similar-to", "{}", now),
    )
    conn.commit()

    client = TestClient(app)
    resp = client.get("/api/graph/full")
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["edges"]) >= 1
    edge = next(e for e in body["edges"] if e["kind"] == "similar-to")
    for field in ("source", "target", "kind", "system"):
        assert field in edge, f"Missing edge field: {field}"


# ── 4c — sidebar + partial indicator in brain3d.html ─────────────────────────

def test_brain3d_has_node_sidebar():
    """Task 4.14: brain3d.html includes a click-node side panel."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    assert "node-sidebar" in brain3d_html or "sidebar" in brain3d_html.lower()


def test_brain3d_handles_partial_indicator():
    """Task 4.17: brain3d.html shows an indicator when partial:true."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    assert "partial" in brain3d_html


def test_brain3d_has_loading_state():
    """brain3d.html shows a loading state while /api/graph/full fetches."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    # The template must have some loading indicator.
    assert "Cargando" in brain3d_html or "loading" in brain3d_html.lower()


def test_brain3d_has_empty_state():
    """brain3d.html shows a friendly message when nodes list is empty."""
    brain3d_html = (TEMPLATES_DIR / "brain3d.html").read_text()
    assert "nodos" in brain3d_html.lower() or "vacío" in brain3d_html or "sin datos" in brain3d_html.lower()
