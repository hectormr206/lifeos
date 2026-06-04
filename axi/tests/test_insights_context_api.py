"""Smoke tests for the /api/insights/context endpoint."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(monkeypatch, tmp_path):
    """Minimal client fixture that stubs dashboard helpers and lifeos stores."""
    # Point lifeos stores at temp files so we don't touch production data.
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "ex.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "ex.key"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit.key"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learn.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learn.key"))
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", str(tmp_path / "ev.db"))
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", str(tmp_path / "ev.key"))

    # Apply migrations so the stores are initialized.
    from lifeos import store as core_store
    from lifeos.health import store as h_store
    from lifeos.finance import store as f_store
    from lifeos.relationships import store as r_store
    from lifeos.exercise import store as e_store
    from lifeos.spirituality import store as s_store
    from lifeos.learning import store as l_store
    from lifeos.events import store as ev_store
    core_store.apply_migrations()
    h_store.apply_migrations()
    f_store.apply_migrations()
    r_store.apply_migrations()
    e_store.apply_migrations()
    s_store.apply_migrations()
    l_store.apply_migrations()
    ev_store.apply_migrations()

    from axi import dashboard
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


# ─── Smoke tests ──────────────────────────────────────────────────────────────

def test_insights_context_returns_200(client) -> None:
    r = client.get("/api/insights/context")
    assert r.status_code == 200


def test_insights_context_response_shape(client) -> None:
    """Response must have 'patterns', 'edges', and 'summary' keys."""
    r = client.get("/api/insights/context")
    assert r.status_code == 200
    data = r.json()
    assert "patterns" in data
    assert "edges" in data
    assert "summary" in data


def test_insights_context_empty_stores_returns_lists(client) -> None:
    """With empty domain stores, patterns and edges should be empty lists."""
    r = client.get("/api/insights/context")
    data = r.json()
    assert isinstance(data["patterns"], list)
    assert isinstance(data["edges"], list)
    assert isinstance(data["summary"], str)


def test_insights_context_with_mocked_bundle(client, monkeypatch) -> None:
    """When build_bundle returns a bundle with content, endpoint reflects it."""
    from lifeos.insights.correlate import CorrelationBundle
    from lifeos.insights.patterns import Pattern

    mock_bundle = CorrelationBundle(
        active_patterns=[
            Pattern(kind="sleep_deficit", message="Dormís poco", severity="warning"),
        ],
        relevant_edges=[],
        edge_summary="Contexto de vida actual:\n- Patrones activos:\n  · Dormís poco",
    )

    with patch("lifeos.insights.correlate.build_bundle", return_value=mock_bundle):
        r = client.get("/api/insights/context")

    assert r.status_code == 200
    data = r.json()
    assert len(data["patterns"]) == 1
    assert data["patterns"][0]["kind"] == "sleep_deficit"
    assert data["summary"] != ""
    # Summary contains the human-readable content from the bundle
    assert "Contexto de vida actual" in data["summary"]


def test_insights_context_edge_metadata_serialized(client) -> None:
    """A correlates-with edge serializes rel + non-empty metadata.note."""
    from lifeos.edges import Edge
    from lifeos.insights.correlate import CorrelationBundle

    edge = Edge(
        id="e1", src_id="sleep", src_domain="health",
        dst_id="spend", dst_domain="finance", rel="correlates-with",
        metadata={"note": "Compras impulsivas 2.3x tras mal sueño.", "strength": 0.82},
    )
    mock_bundle = CorrelationBundle(
        active_patterns=[], relevant_edges=[edge],
        edge_summary="Contexto de vida actual:",
    )
    with patch("lifeos.insights.correlate.build_bundle", return_value=mock_bundle):
        r = client.get("/api/insights/context")
    assert r.status_code == 200
    edges = r.json()["edges"]
    assert len(edges) == 1
    assert edges[0]["rel"] == "correlates-with"
    assert edges[0]["metadata"]["note"]  # non-empty


def test_insights_preview_includes_correlations_count(client) -> None:
    """GET /api/insights/preview must return JSON with a 'correlations_count' key."""
    r = client.get("/api/insights/preview")
    assert r.status_code == 200
    data = r.json()
    assert "correlations_count" in data
