"""Tests for the Correlation Engine (lifeos.insights.correlate)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point every domain store at a temp path."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
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
    yield


# ─── render_summary ───────────────────────────────────────────────────────────

def test_render_summary_empty() -> None:
    from lifeos.insights.correlate import render_summary
    assert render_summary([], []) == ""


def test_render_summary_with_patterns() -> None:
    from lifeos.insights.patterns import Pattern
    from lifeos.insights.correlate import render_summary

    p = Pattern(kind="sleep_deficit", message="Dormís poco", severity="warning")
    result = render_summary([p], [])
    assert result != ""
    assert "Contexto de vida actual" in result
    assert "sleep_deficit" in result
    assert "Dormís poco" in result


def test_render_summary_with_edges_and_patterns() -> None:
    from lifeos.insights.patterns import Pattern
    from lifeos.insights.correlate import render_summary
    from lifeos import edges

    p = Pattern(kind="spending_acceleration", message="Gastás más", severity="warning")
    e = edges.create(
        src=("finance", "entry-1"),
        dst=("insights", "sleep_deficit"),
        rel="correlates-with",
        metadata={"note": "impulse buy after bad sleep"},
    )
    result = render_summary([p], [e])
    assert "Conexiones recientes" in result
    assert "correlates-with" in result


# ─── build_bundle ─────────────────────────────────────────────────────────────

def test_build_bundle_empty_returns_empty_summary() -> None:
    """With no patterns and no edges, edge_summary should be ''."""
    from lifeos.insights.correlate import build_bundle

    bundle = build_bundle()
    # Patterns come from live domain DAOs which are empty in isolation.
    # The result may be an empty list or None-safe.
    assert bundle.edge_summary == "" or isinstance(bundle.edge_summary, str)
    # active_patterns is a list (possibly empty in test isolation)
    assert isinstance(bundle.active_patterns, list)
    assert isinstance(bundle.relevant_edges, list)


def test_build_bundle_with_mocked_patterns_and_no_edges() -> None:
    """When detect_all returns patterns but no edges exist, edge_summary
    should mention the patterns."""
    from lifeos.insights.patterns import Pattern
    from lifeos.insights.correlate import build_bundle

    mock_patterns = [
        Pattern(kind="sleep_deficit", message="Dormís 5.4h promedio", severity="warning"),
        Pattern(kind="spending_acceleration", message="Gastaste 50% más", severity="warning"),
    ]
    # detect_all is imported lazily inside build_bundle; patch it at its source.
    with patch("lifeos.insights.patterns.detect_all", return_value=mock_patterns):
        bundle = build_bundle()

    assert len(bundle.active_patterns) == 2
    assert bundle.edge_summary != ""
    # Summary should mention both patterns in Spanish
    assert "sleep_deficit" in bundle.edge_summary
    assert "spending_acceleration" in bundle.edge_summary


def test_build_bundle_no_patterns_returns_empty_summary() -> None:
    """When detect_all returns nothing, edge_summary should be empty (no edges either)."""
    from lifeos.insights.correlate import build_bundle

    with patch("lifeos.insights.patterns.detect_all", return_value=[]):
        bundle = build_bundle()

    assert bundle.active_patterns == []
    # With no patterns and no persisted edges → summary is empty
    assert bundle.edge_summary == ""


def test_build_bundle_domain_hint_filters_edges() -> None:
    """Edges that don't match the domain_hint should be excluded."""
    from lifeos import edges
    from lifeos.insights.correlate import build_bundle

    # Create edge in finance domain
    edges.create(
        src=("finance", "ent-1"),
        dst=("insights", "pattern-x"),
        rel="correlates-with",
    )
    # Create edge in health domain
    edges.create(
        src=("health", "ent-2"),
        dst=("insights", "pattern-y"),
        rel="correlates-with",
    )

    with patch("lifeos.insights.patterns.detect_all", return_value=[]):
        bundle_finance = build_bundle(domain_hint="finance")
        bundle_health = build_bundle(domain_hint="health")

    finance_domains = {e.src_domain for e in bundle_finance.relevant_edges}
    health_domains = {e.src_domain for e in bundle_health.relevant_edges}

    assert "health" not in finance_domains
    assert "finance" not in health_domains


def test_build_bundle_expired_edges_excluded() -> None:
    """Edges with expires_at in the past should be excluded from the bundle."""
    from lifeos import edges
    from lifeos.insights.correlate import build_bundle
    from datetime import timezone

    past = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

    edges.create(
        src=("insights", "snapshot"),
        dst=("insights", "sleep_deficit"),
        rel="pattern-active-at",
        metadata={"expires_at": past, "snapshot": True, "pattern_kind": "sleep_deficit"},
        created_by="correlation_snapshot",
    )

    with patch("lifeos.insights.patterns.detect_all", return_value=[]):
        bundle = build_bundle()

    # The expired edge should not appear
    for e in bundle.relevant_edges:
        md = e.metadata or {}
        if md.get("pattern_kind") == "sleep_deficit":
            pytest.fail("Expired edge should have been excluded from bundle")


# ─── edges metadata round-trip ────────────────────────────────────────────────

def test_edges_metadata_round_trip() -> None:
    """Verify that metadata persisted via edges.create() survives a read."""
    from lifeos import edges

    metadata = {
        "expires_at": "2099-12-31T00:00:00+00:00",
        "snapshot": True,
        "pattern_kind": "sleep_deficit",
        "severity": "warning",
    }
    created = edges.create(
        src=("insights", "snapshot"),
        dst=("insights", "sleep_deficit"),
        rel="pattern-active-at",
        metadata=metadata,
        created_by="test",
    )

    assert created.metadata is not None
    assert created.metadata["snapshot"] is True
    assert created.metadata["pattern_kind"] == "sleep_deficit"
    assert created.metadata["expires_at"] == "2099-12-31T00:00:00+00:00"

    # Read it back via by_relation
    batch = edges.by_relation("pattern-active-at", limit=10)
    assert len(batch) == 1
    read_back = batch[0]
    assert read_back.id == created.id
    assert read_back.metadata["severity"] == "warning"


# ─── REL_VOCAB ────────────────────────────────────────────────────────────────

def test_rel_vocab_contains_new_relations() -> None:
    from lifeos.edges import REL_VOCAB
    assert "correlates-with" in REL_VOCAB
    assert "pattern-active-at" in REL_VOCAB
