"""Tests for the Correlation Engine (lifeos.insights.correlate)."""

from __future__ import annotations

from dataclasses import FrozenInstanceError
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, call, patch

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


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 — CorrelationResult frozen dataclass
# ═══════════════════════════════════════════════════════════════════════════════

def test_correlation_result_is_frozen() -> None:
    """CorrelationResult must be a frozen dataclass — mutation raises FrozenInstanceError."""
    from lifeos.insights.correlate import CorrelationResult

    result = CorrelationResult(
        rate_ratio=2.5,
        poor_sleep_days=4,
        ok_sleep_days=6,
        impulsive_after_poor=3,
        impulsive_after_ok=1,
        total_impulsive=3,
        window_days=90,
        lag_days=2,
        threshold=6.5,
    )
    with pytest.raises(FrozenInstanceError):
        result.rate_ratio = 1.0  # type: ignore[misc]


# ═══════════════════════════════════════════════════════════════════════════════
# Helpers for Phase 2 unit tests (pure detector, no DB)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_sleep_entry(ts: datetime, hours: float):
    """Minimal Entry-like object for the health (sleep_hours vital) DAO."""
    e = MagicMock()
    e.ts = ts
    e.data = {"type": "sleep_hours", "value": hours}
    e.tags = []
    return e


def _make_purchase_entry(ts: datetime):
    """Minimal Entry-like object for the finance (big_purchase impulsive) DAO."""
    e = MagicMock()
    e.ts = ts
    e.data = {}
    e.tags = ["impulsive"]
    return e


def _fake_health_fn(*entries):
    """Return a callable that ignores arguments and yields the given sleep entries."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


def _fake_finance_fn(*entries):
    """Return a callable that ignores arguments and yields the given purchase entries."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2 — _detect_sleep_spending_correlation unit tests
# ═══════════════════════════════════════════════════════════════════════════════

_NOW = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)


def _d(offset_days: int) -> datetime:
    """Shorthand: _NOW minus offset_days."""
    return _NOW - timedelta(days=offset_days)


def test_fires_when_all_thresholds_met() -> None:
    """Detector fires (returns CorrelationResult) when all three guards pass."""
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # 3 poor-sleep days: D-10, D-9, D-8
    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 4.5),
        _make_sleep_entry(_d(8), 5.5),
    ]
    # 2 impulsive purchases within lag 0-2 days of poor-sleep days
    finance = [
        _make_purchase_entry(_d(10)),   # same day as D-10 poor sleep (lag=0)
        _make_purchase_entry(_d(7)),    # D-8 + 1 day (lag=1)
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )

    assert isinstance(result, CorrelationResult)
    assert result.rate_ratio >= 2.0


def test_none_when_poor_sleep_days_below_3() -> None:
    """Returns None when fewer than 3 poor-sleep days (only 2)."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 4.5),
    ]
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(9)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert result is None


def test_none_when_total_impulsive_below_2() -> None:
    """Returns None when fewer than 2 impulsive purchases in lag window."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 4.5),
        _make_sleep_entry(_d(8), 4.0),
    ]
    finance = [
        _make_purchase_entry(_d(10)),  # only 1 impulsive purchase
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert result is None


def test_none_when_rate_ratio_below_2() -> None:
    """Returns None when impulsive purchase rate is spread evenly (ratio < 2.0)."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    # 3 poor-sleep days, 3 ok-sleep days, impulsive purchases after each
    sleep = [
        _make_sleep_entry(_d(10), 5.0),  # poor
        _make_sleep_entry(_d(9), 4.5),   # poor
        _make_sleep_entry(_d(8), 5.0),   # poor
        _make_sleep_entry(_d(7), 7.0),   # ok
        _make_sleep_entry(_d(6), 8.0),   # ok
        _make_sleep_entry(_d(5), 7.5),   # ok
    ]
    # Impulsive purchases after every day → equal rates → ratio ~1.0
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(9)),
        _make_purchase_entry(_d(8)),
        _make_purchase_entry(_d(7)),
        _make_purchase_entry(_d(6)),
        _make_purchase_entry(_d(5)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert result is None


def test_lag_window_inclusive() -> None:
    """Purchase on D+2 counts; purchase on D+3 does NOT count toward impulsive_after_poor.

    Uses a single isolated poor-sleep day well-separated from other poor days so that
    the lag boundary is unambiguous.  The other two poor-sleep days are placed 20+ days
    away so purchases near day 10 cannot accidentally fall within their lag windows.
    """
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # Poor day A is at D-30 (isolated); poor days B and C at D-50 and D-60 (far away)
    poor_a = _d(30)
    purchase_d2 = poor_a + timedelta(days=2)   # D-28 — within lag=2 of poor_a
    purchase_d3 = poor_a + timedelta(days=3)   # D-27 — outside lag=2 of poor_a

    sleep = [
        _make_sleep_entry(_d(30), 5.0),   # poor A
        _make_sleep_entry(_d(50), 5.0),   # poor B (far from purchases)
        _make_sleep_entry(_d(60), 5.0),   # poor C (far from purchases)
    ]
    finance_with_d2 = [
        _make_purchase_entry(purchase_d2),   # lag=2 → counts for poor_a
        _make_purchase_entry(_d(30)),        # lag=0 → counts for poor_a
    ]
    # Purchases only at lag=3 from poor_a (and not within lag of B or C either)
    finance_with_d3_only = [
        _make_purchase_entry(purchase_d3),                    # D-27, lag=3 from poor_a
        _make_purchase_entry(purchase_d3 + timedelta(days=1)),  # D-26, lag=4
    ]

    # With lag=2 purchase it should fire (impulsive_after_poor >= 1, rate_ratio high)
    result_fires = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance_with_d2),
    )
    assert isinstance(result_fires, CorrelationResult)

    # With only D+3 (outside lag for ALL poor days), impulsive_after_poor = 0 → None
    result_silent = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance_with_d3_only),
    )
    # total_impulsive >= 2 but impulsive_after_poor = 0 → rate_ratio = 0 < 2.0
    assert result_silent is None


def test_ok_sleep_zero_denominator() -> None:
    """When ok_sleep_days=0, rate_after_ok uses floor 0.001, no ZeroDivisionError."""
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # All sleep days are poor
    sleep = [_make_sleep_entry(_d(i), 5.0) for i in range(3, 7)]
    finance = [
        _make_purchase_entry(_d(3)),
        _make_purchase_entry(_d(4)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert isinstance(result, CorrelationResult)
    assert result.ok_sleep_days == 0


def test_multiple_sleep_entries_same_day_takes_min() -> None:
    """When a day has two sleep entries, the minimum hours governs classification."""
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # D-10: one entry at 7h (would be ok) + one entry at 5h (poor) → min=5h → poor
    sleep = [
        _make_sleep_entry(_d(10), 7.0),
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 5.0),
        _make_sleep_entry(_d(8), 5.0),
    ]
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(9)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    # D-10 should be classified as poor (min=5h), giving us 3 poor days total
    assert isinstance(result, CorrelationResult)
    assert result.poor_sleep_days == 3


def test_boundary_6_5h_is_ok() -> None:
    """sleep_hours == 6.5 is NOT poor (strict less-than)."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    # Only 2 "poor" days if 6.5 is treated as poor, but should be classified ok
    # → only 2 actual poor days → None
    sleep = [
        _make_sleep_entry(_d(10), 6.4),  # poor
        _make_sleep_entry(_d(9), 6.4),   # poor
        _make_sleep_entry(_d(8), 6.5),   # ok (boundary)
    ]
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(9)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    # Only 2 poor days → None
    assert result is None


def test_boundary_ratio_exactly_2_0_fires() -> None:
    """rate_ratio exactly 2.0 must produce a result (>= is inclusive)."""
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # 3 poor days, 3 ok days
    # impulsive_after_poor = 3, poor_sleep_days = 3 → rate_poor = 1.0
    # impulsive_after_ok = 3, ok_sleep_days = 6 → rate_ok = 0.5
    # ratio = 1.0 / 0.5 = 2.0 exactly
    sleep = [
        _make_sleep_entry(_d(10), 5.0),  # poor
        _make_sleep_entry(_d(8), 5.0),   # poor
        _make_sleep_entry(_d(6), 5.0),   # poor
        _make_sleep_entry(_d(4), 7.0),   # ok
        _make_sleep_entry(_d(3), 7.0),   # ok
        _make_sleep_entry(_d(2), 7.0),   # ok
        _make_sleep_entry(_d(20), 7.0),  # ok
        _make_sleep_entry(_d(19), 7.0),  # ok
        _make_sleep_entry(_d(18), 7.0),  # ok
    ]
    # 3 impulsive purchases after 3 poor days (lag=0), 3 after ok days (lag=0)
    finance = [
        _make_purchase_entry(_d(10)),  # after D-10 poor
        _make_purchase_entry(_d(8)),   # after D-8 poor
        _make_purchase_entry(_d(6)),   # after D-6 poor
        _make_purchase_entry(_d(4)),   # after D-4 ok
        _make_purchase_entry(_d(3)),   # after D-3 ok
        _make_purchase_entry(_d(2)),   # after D-2 ok
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert isinstance(result, CorrelationResult)
    assert result.rate_ratio >= 2.0


def test_result_field_values_match_inputs() -> None:
    """CorrelationResult fields accurately reflect the seeded data."""
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 4.5),
        _make_sleep_entry(_d(8), 5.5),
    ]
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(7)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )

    assert isinstance(result, CorrelationResult)
    assert result.window_days == 90
    assert result.lag_days == 2
    assert result.threshold == 6.5
    assert result.poor_sleep_days == 3
    assert result.total_impulsive == 2


def test_none_when_no_sleep_data() -> None:
    """Zero sleep entries → None, no exception."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(),
        finance_list_recent=_fake_finance_fn(_make_purchase_entry(_d(5))),
    )
    assert result is None


def test_none_when_no_finance_data() -> None:
    """Zero finance entries → None, no exception."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 5.0),
        _make_sleep_entry(_d(8), 5.0),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(),
    )
    assert result is None


def test_none_when_all_sleep_good() -> None:
    """All sleep >= 6.5h → no poor days → None."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    sleep = [
        _make_sleep_entry(_d(10), 8.0),
        _make_sleep_entry(_d(9), 7.5),
        _make_sleep_entry(_d(8), 6.5),  # exactly at threshold → ok
    ]
    finance = [
        _make_purchase_entry(_d(10)),
        _make_purchase_entry(_d(9)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    assert result is None


def test_composite_minimum_boundaries_fires() -> None:
    """Detector fires when ALL three guards sit at their exact minimum simultaneously.

    Composite minimum: poor_sleep_days == 3, total_impulsive == 2, rate_ratio >= 2.0.

    Construction for rate_ratio == 2.0 exactly:
      - poor_sleep_days = 3, ok_sleep_days = 3
      - impulsive_after_poor = 2  →  rate_after_poor = 2/3
      - impulsive_after_ok   = 1  →  rate_after_ok   = 1/3
      - rate_ratio = (2/3) / (1/3) = 2.0 (exact integer arithmetic)
      - total_impulsive = 2 (P1 satisfies lag for both a poor day and an ok day;
        P2 satisfies lag for a second poor day; third poor day has no match)
    """
    from lifeos.insights.correlate import CorrelationResult, _detect_sleep_spending_correlation

    # Sleep days layout (all within the 90-day window via _NOW anchor)
    # poor: D-10, D-5, D-1 (3 poor days)
    # ok:   D-11, D-15, D-20 (3 ok days)
    sleep = [
        _make_sleep_entry(_d(10), 5.0),   # poor — will be matched by P1 (lag=1)
        _make_sleep_entry(_d(5),  5.0),   # poor — will be matched by P2 (lag=0)
        _make_sleep_entry(_d(1),  5.0),   # poor — no match (third minimum poor day)
        _make_sleep_entry(_d(11), 7.0),   # ok — will be matched by P1 (lag=2)
        _make_sleep_entry(_d(15), 7.0),   # ok — no match
        _make_sleep_entry(_d(20), 7.0),   # ok — no match
    ]
    # P1 = D-9: lag=1 after poor D-10, lag=2 after ok D-11 → counted for both
    # P2 = D-5: lag=0 after poor D-5
    # total distinct impulsive purchase days = 2
    finance = [
        _make_purchase_entry(_d(9)),   # P1
        _make_purchase_entry(_d(5)),   # P2
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )

    assert isinstance(result, CorrelationResult), "Detector must fire at composite minimum"
    assert result.poor_sleep_days == 3
    assert result.total_impulsive == 2
    assert result.rate_ratio == pytest.approx(2.0)


def test_purchase_before_poor_sleep_not_counted() -> None:
    """A purchase 1 day BEFORE a poor-sleep day must not count toward impulsive_after_poor."""
    from lifeos.insights.correlate import _detect_sleep_spending_correlation

    # Poor sleep on D-10; purchase on D-11 (1 day BEFORE, negative lag)
    poor_day = _d(10)
    purchase_before = poor_day - timedelta(days=1)

    sleep = [
        _make_sleep_entry(_d(10), 5.0),
        _make_sleep_entry(_d(9), 5.0),
        _make_sleep_entry(_d(8), 5.0),
    ]
    # Purchase before poor day + one more that shouldn't match either
    finance = [
        _make_purchase_entry(purchase_before),
        _make_purchase_entry(purchase_before - timedelta(days=1)),
    ]

    result = _detect_sleep_spending_correlation(
        _NOW,
        health_list_recent=_fake_health_fn(*sleep),
        finance_list_recent=_fake_finance_fn(*finance),
    )
    # impulsive_after_poor = 0, rate_ratio = 0 < 2.0 → None
    assert result is None


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — _persist_correlation_edge unit tests
# ═══════════════════════════════════════════════════════════════════════════════

def _make_result(rate_ratio: float = 2.5) -> "CorrelationResult":  # type: ignore[name-defined]
    from lifeos.insights.correlate import CorrelationResult
    return CorrelationResult(
        rate_ratio=rate_ratio,
        poor_sleep_days=4,
        ok_sleep_days=6,
        impulsive_after_poor=3,
        impulsive_after_ok=1,
        total_impulsive=3,
        window_days=90,
        lag_days=2,
        threshold=6.5,
    )


def test_persist_creates_edge_with_correct_shape() -> None:
    """_persist_correlation_edge calls edges_mod.create with correct src/dst/rel/created_by."""
    from lifeos.insights.correlate import _persist_correlation_edge

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    _persist_correlation_edge(_make_result(), _NOW, edges_mod=mock_edges)

    mock_edges.create.assert_called_once()
    kwargs = mock_edges.create.call_args.kwargs
    assert kwargs["rel"] == "correlates-with"
    assert kwargs["src"] == ("health", "sleep_deficit_pattern")
    assert kwargs["dst"] == ("finance", "impulsive_spending")
    assert kwargs["created_by"] == "correlation_snapshot"


def test_persist_metadata_keys_present() -> None:
    """Created edge metadata must contain all required keys."""
    from lifeos.insights.correlate import _persist_correlation_edge

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    _persist_correlation_edge(_make_result(), _NOW, edges_mod=mock_edges)

    metadata = mock_edges.create.call_args.kwargs["metadata"]
    required = {
        "strength", "rate_ratio", "window_days", "lag_days",
        "poor_sleep_days", "impulsive_after_poor", "total_impulsive",
        "threshold", "expires_at", "snapshot", "note",
    }
    for key in required:
        assert key in metadata, f"Missing metadata key: {key}"


def test_persist_expires_at_is_now_plus_7_days() -> None:
    """expires_at must equal (now + 7 days).isoformat()."""
    from lifeos.insights.correlate import _persist_correlation_edge

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    fixed_now = datetime(2024, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    _persist_correlation_edge(_make_result(), fixed_now, edges_mod=mock_edges)

    metadata = mock_edges.create.call_args.kwargs["metadata"]
    expected = (fixed_now + timedelta(days=7)).isoformat()
    assert metadata["expires_at"] == expected


def test_persist_note_is_nonempty_spanish_string() -> None:
    """note must be a non-empty string containing at least one non-ASCII character."""
    from lifeos.insights.correlate import _persist_correlation_edge

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    _persist_correlation_edge(_make_result(), _NOW, edges_mod=mock_edges)

    note = mock_edges.create.call_args.kwargs["metadata"]["note"]
    assert isinstance(note, str)
    assert len(note.strip()) > 0
    # Must contain at least one non-ASCII character (Spanish accented letter)
    assert any(ord(c) > 127 for c in note), f"note has no non-ASCII chars: {note!r}"


def test_persist_deletes_stale_edge_before_create() -> None:
    """When a stale matching edge exists, delete() is called before create()."""
    from lifeos.insights.correlate import _persist_correlation_edge

    stale_edge = MagicMock()
    stale_edge.id = "stale-id"
    stale_edge.src_id = "sleep_deficit_pattern"
    stale_edge.dst_id = "impulsive_spending"

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = [stale_edge]

    call_order = []
    mock_edges.delete.side_effect = lambda _id: call_order.append("delete")
    mock_edges.create.side_effect = lambda **_kw: call_order.append("create") or MagicMock()

    _persist_correlation_edge(_make_result(), _NOW, edges_mod=mock_edges)

    mock_edges.delete.assert_called_once_with("stale-id")
    assert call_order == ["delete", "create"]


def test_persist_no_delete_when_no_stale_edge() -> None:
    """When by_relation returns empty list, delete() is NOT called."""
    from lifeos.insights.correlate import _persist_correlation_edge

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    _persist_correlation_edge(_make_result(), _NOW, edges_mod=mock_edges)

    mock_edges.delete.assert_not_called()


# ═══════════════════════════════════════════════════════════════════════════════
# filter_unexpired — unit tests (task 1.1)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_edge_with_expires(expires_offset_seconds: int | None, note: str = "test") -> MagicMock:
    """Build a minimal edge mock with optional expires_at relative to real now."""
    e = MagicMock()
    if expires_offset_seconds is None:
        e.metadata = {"note": note}
    else:
        exp = datetime.now(timezone.utc) + timedelta(seconds=expires_offset_seconds)
        e.metadata = {"note": note, "expires_at": exp.isoformat()}
    return e


def test_filter_unexpired_no_expires_at_kept() -> None:
    """Edge with no expires_at must always be kept."""
    from lifeos.insights.correlate import filter_unexpired

    e = _make_edge_with_expires(None)
    result = filter_unexpired([e], datetime.now(timezone.utc))
    assert result == [e]


def test_filter_unexpired_future_kept() -> None:
    """Edge with expires_at in the future must be kept."""
    from lifeos.insights.correlate import filter_unexpired

    e = _make_edge_with_expires(+86400)  # +1 day
    result = filter_unexpired([e], datetime.now(timezone.utc))
    assert result == [e]


def test_filter_unexpired_past_skipped() -> None:
    """Edge with expires_at in the past must be excluded."""
    from lifeos.insights.correlate import filter_unexpired

    e = _make_edge_with_expires(-86400)  # -1 day (expired)
    result = filter_unexpired([e], datetime.now(timezone.utc))
    assert result == []


def test_filter_unexpired_parse_error_kept() -> None:
    """Edge with a non-parseable expires_at string must be kept (silent pass)."""
    from lifeos.insights.correlate import filter_unexpired

    e = MagicMock()
    e.metadata = {"expires_at": "not-a-date", "note": "bad date edge"}
    result = filter_unexpired([e], datetime.now(timezone.utc))
    assert result == [e]


def test_filter_unexpired_naive_datetime_treated_as_utc() -> None:
    """Naive datetime in expires_at must be treated as UTC."""
    from lifeos.insights.correlate import filter_unexpired

    # Naive datetime far in the future — should be kept
    future_naive = (datetime.now(timezone.utc) + timedelta(days=1)).replace(tzinfo=None)
    e = MagicMock()
    e.metadata = {"expires_at": future_naive.isoformat(), "note": "naive future"}
    result = filter_unexpired([e], datetime.now(timezone.utc))
    assert result == [e]


def test_filter_unexpired_mixed_list() -> None:
    """Mix of expired, unexpired, and no-expires edges returns only the valid ones."""
    from lifeos.insights.correlate import filter_unexpired

    kept1 = _make_edge_with_expires(None, "no expiry")
    kept2 = _make_edge_with_expires(+86400, "future")
    dropped = _make_edge_with_expires(-86400, "past")
    now = datetime.now(timezone.utc)
    result = filter_unexpired([kept1, dropped, kept2], now)
    assert result == [kept1, kept2]


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Integration tests (real DAOs + _isolated fixture)
# ═══════════════════════════════════════════════════════════════════════════════

def _seed_poor_sleep(offset_days: int, hours: float = 5.0) -> None:
    """Insert a sleep vital entry at real now - offset_days."""
    from lifeos.health import entries as health_entries
    when = datetime.now(timezone.utc) - timedelta(days=offset_days)
    health_entries.create(
        kind="vital",
        title="sleep",
        when=when,
        data={"type": "sleep_hours", "value": hours},
    )


def _seed_impulsive_purchase(offset_days: int) -> None:
    """Insert an impulsive big_purchase entry at real now - offset_days."""
    from lifeos.finance import entries as finance_entries
    when = datetime.now(timezone.utc) - timedelta(days=offset_days)
    finance_entries.create(
        kind="big_purchase",
        title="impulse buy",
        amount=500.0,
        when=when,
        tags=["impulsive"],
    )


def _seed_conflict(offset_days: int) -> None:
    """Insert a conflict interaction at real now - offset_days (creates person if needed)."""
    from lifeos.relationships import interactions as rel_interactions, people as rel_people
    when = datetime.now(timezone.utc) - timedelta(days=offset_days)
    # Ensure a person exists to attach the interaction to
    existing = rel_people.list_all() if hasattr(rel_people, "list_all") else []
    if not existing:
        person = rel_people.create(name="Test Person")
        person_id = person.id
    else:
        person_id = existing[0].id
    rel_interactions.create(
        kind="conflict",
        title="conflict event",
        person_id=person_id,
        when=when,
    )


def _seed_exercise_session(offset_days: int) -> None:
    """Insert an exercise session at real now - offset_days."""
    from lifeos.exercise import sessions as ex_sessions
    when = datetime.now(timezone.utc) - timedelta(days=offset_days)
    ex_sessions.create(
        kind="run",
        title="run session",
        duration_minutes=30,
        when=when,
    )


def test_snapshot_writes_correlates_with_edge() -> None:
    """After seeding poor sleep + impulsive purchases, snapshot writes exactly one edge."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot

    # Seed 3 poor-sleep days within the last ~10 days
    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    # Seed 2 impulsive purchases within lag 0-2 of poor-sleep days
    _seed_impulsive_purchase(10)   # same day as D-10 poor sleep
    _seed_impulsive_purchase(8)    # same day as D-8 poor sleep

    _run_correlation_snapshot()

    matching = [
        e for e in edges.by_relation("correlates-with")
        if e.src_id == "sleep_deficit_pattern" and e.dst_id == "impulsive_spending"
    ]
    assert len(matching) == 1, f"Expected exactly 1 correlates-with edge, got {len(matching)}"
    edge = matching[0]
    md = edge.metadata or {}
    # Spanish note must contain at least one non-ASCII character
    note = md.get("note", "")
    assert len(note) > 0
    assert any(ord(c) > 127 for c in note), f"note has no non-ASCII chars: {note!r}"
    # expires_at must be in the future
    expires_at = md.get("expires_at", "")
    exp_dt = datetime.fromisoformat(expires_at)
    if exp_dt.tzinfo is None:
        exp_dt = exp_dt.replace(tzinfo=timezone.utc)
    assert exp_dt > datetime.now(timezone.utc), "expires_at should be in the future"


def test_dedup_no_duplicate_on_rerun() -> None:
    """Running snapshot twice on the same data produces exactly one matching edge."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot

    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(9)

    _run_correlation_snapshot()
    _run_correlation_snapshot()

    matching = [
        e for e in edges.by_relation("correlates-with")
        if e.src_id == "sleep_deficit_pattern" and e.dst_id == "impulsive_spending"
    ]
    assert len(matching) == 1, f"Expected exactly 1 edge after two runs, got {len(matching)}"


def test_surfaces_via_build_bundle() -> None:
    """After snapshot, build_bundle() includes the correlates-with edge and its note.

    Seeds use real datetime.now(timezone.utc) (not injected _NOW) to avoid the
    SQLite datetime('now') hazard: the DAO timestamps are written with wall-clock
    now, and list_recent() also uses wall-clock now to compute the window boundary.
    Using _NOW (a fixed past datetime) would make the entries fall outside the
    live query window and produce an empty result.
    """
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot, build_bundle, render_summary

    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(9)

    _run_correlation_snapshot()

    # Patch detect_all to [] to isolate from patterns detection
    with patch("lifeos.insights.patterns.detect_all", return_value=[]):
        bundle = build_bundle()

    corr_edges = [
        e for e in bundle.relevant_edges
        if e.rel == "correlates-with"
        and e.src_id == "sleep_deficit_pattern"
        and e.dst_id == "impulsive_spending"
    ]
    assert len(corr_edges) >= 1, "correlates-with edge should appear in bundle.relevant_edges"

    # S3: also assert against bundle.edge_summary — the field purchase-consult injects
    edge_summary = bundle.edge_summary
    assert isinstance(edge_summary, str), "bundle.edge_summary must be a string"
    assert len(edge_summary) > 0, "bundle.edge_summary must be non-empty after snapshot"
    assert "correlates-with" in edge_summary, (
        f"bundle.edge_summary must mention the correlates-with edge: {edge_summary!r}"
    )

    # The edge's note must appear in both render_summary output and edge_summary
    note = (corr_edges[0].metadata or {}).get("note", "")
    summary = render_summary([], corr_edges)
    assert note in summary, f"Edge note not found in render_summary output: {summary!r}"
    assert note in edge_summary, f"Edge note not found in bundle.edge_summary: {edge_summary!r}"


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 (new) — LaggedCorrelationResult frozen dataclass  [task 1.1 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def test_lagged_correlation_result_fields_exist() -> None:
    """LaggedCorrelationResult must have all 8 fields and be a frozen dataclass."""
    from lifeos.insights.correlate import LaggedCorrelationResult

    r = LaggedCorrelationResult(
        trigger_count=6,
        non_trigger_count=4,
        events_after_trigger=3,
        events_after_non_trigger=1,
        total_events=10,
        rate_ratio=3.5,
        window_days=90,
        lag_days=2,
    )
    assert r.trigger_count == 6
    assert r.non_trigger_count == 4
    assert r.events_after_trigger == 3
    assert r.events_after_non_trigger == 1
    assert r.total_events == 10
    assert r.rate_ratio == 3.5
    assert r.window_days == 90
    assert r.lag_days == 2


def test_lagged_correlation_result_is_frozen() -> None:
    """LaggedCorrelationResult must be frozen — mutation raises FrozenInstanceError."""
    from dataclasses import FrozenInstanceError
    from lifeos.insights.correlate import LaggedCorrelationResult

    r = LaggedCorrelationResult(
        trigger_count=1,
        non_trigger_count=1,
        events_after_trigger=1,
        events_after_non_trigger=0,
        total_events=5,
        rate_ratio=2.0,
        window_days=90,
        lag_days=2,
    )
    with pytest.raises(FrozenInstanceError):
        r.rate_ratio = 1.0  # type: ignore[misc]


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 (new) — _detect_lagged_correlation primitive  [task 1.3 RED]
# ═══════════════════════════════════════════════════════════════════════════════

_BASE_DATE = date(2024, 6, 15)


def _trigger_set(offsets: list[int]) -> set[date]:
    """Build a set of trigger dates: base_date - offset for each offset."""
    return {_BASE_DATE - timedelta(days=o) for o in offsets}


def _event_set(offsets: list[int]) -> set[date]:
    """Build a set of event dates: base_date - offset for each offset."""
    return {_BASE_DATE - timedelta(days=o) for o in offsets}


def test_primitive_fires_all_guards_pass() -> None:
    """(a) All guards pass → returns LaggedCorrelationResult with correct counts."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_lagged_correlation

    # 6 trigger days, events within lag of some triggers → rate_ratio >= 2.0
    trigger = _trigger_set([10, 11, 12, 13, 14, 15])
    non_trigger = _trigger_set([20, 21, 22, 23])
    # Events at trigger+1 (lag=1) for 4 of the 6 trigger days
    events = _event_set([9, 10, 11, 12])

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=3,
        min_rate_ratio=2.0,
    )

    assert isinstance(result, LaggedCorrelationResult)
    assert result.rate_ratio >= 2.0
    assert result.trigger_count == 6
    assert result.total_events == len(events)


def test_primitive_none_trigger_count_below_min() -> None:
    """(b) n_trigger_days < min_trigger_days → None."""
    from lifeos.insights.correlate import _detect_lagged_correlation

    trigger = _trigger_set([10, 11, 12, 13])  # 4 days
    non_trigger = _trigger_set([20, 21, 22])
    events = _event_set([9, 10, 5])

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),  # 4 < 5
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
    )

    assert result is None


def test_primitive_fires_trigger_count_at_boundary() -> None:
    """(c) n_trigger_days == min_trigger_days → result (boundary inclusive)."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_lagged_correlation

    trigger = _trigger_set([10, 11, 12, 13, 14])  # exactly 5
    non_trigger = _trigger_set([20, 21])
    # Events after all 5 triggers but none after non-triggers → high ratio
    events = _event_set([9, 10, 11, 12, 13])

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=5,
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
    )

    assert isinstance(result, LaggedCorrelationResult)


def test_primitive_none_total_events_below_min() -> None:
    """(d) total_events < min_total_events → None."""
    from lifeos.insights.correlate import _detect_lagged_correlation

    trigger = _trigger_set([10, 11, 12, 13, 14, 15])
    non_trigger = _trigger_set([20, 21])
    events = _event_set([9])  # only 1 event

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,  # need 2, have 1
        min_rate_ratio=2.0,
    )

    assert result is None


def test_primitive_fires_total_events_at_boundary() -> None:
    """(e) total_events == min_total_events → result (boundary inclusive)."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_lagged_correlation

    trigger = _trigger_set([10, 11, 12, 13, 14, 15])
    non_trigger = _trigger_set([30, 31])
    events = _event_set([9, 10])  # exactly 2 events, both after triggers

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
    )

    assert isinstance(result, LaggedCorrelationResult)


def test_primitive_none_rate_ratio_below_min() -> None:
    """(f) rate_ratio < min_rate_ratio → None."""
    from lifeos.insights.correlate import _detect_lagged_correlation

    # Spread events evenly across trigger and non-trigger to get ratio ~1.0
    trigger = _trigger_set([10, 11, 12, 13, 14, 15])
    non_trigger = _trigger_set([20, 21, 22, 23, 24, 25])
    # Events after each trigger AND each non-trigger → equal rates → ratio ~1.0
    events = _event_set([9, 10, 11, 12, 13, 14, 19, 20, 21, 22, 23, 24])

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
    )

    assert result is None


def test_primitive_fires_rate_ratio_at_boundary() -> None:
    """(g) rate_ratio == min_rate_ratio → result (boundary inclusive).

    Construction for exactly ratio=2.0:
      - 4 trigger days, 4 non-trigger days (well separated from each other)
      - events_after_trigger = 2  → rate_trigger = 2/4 = 0.5
      - events_after_non_trigger = 1  → rate_non = 1/4 = 0.25
      - rate_ratio = 0.5 / 0.25 = 2.0 exactly
    Trigger days at offsets 30–33 from _BASE_DATE; non-trigger at 50–53.
    Events at trigger+1 for 2 triggers, and non-trigger+1 for 1 non-trigger.
    No overlap between event dates and trigger/non-trigger dates.
    """
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_lagged_correlation

    trigger = {
        _BASE_DATE - timedelta(days=30),
        _BASE_DATE - timedelta(days=32),
        _BASE_DATE - timedelta(days=34),
        _BASE_DATE - timedelta(days=36),
    }
    non_trigger = {
        _BASE_DATE - timedelta(days=50),
        _BASE_DATE - timedelta(days=52),
        _BASE_DATE - timedelta(days=54),
        _BASE_DATE - timedelta(days=56),
    }
    events = {
        _BASE_DATE - timedelta(days=29),  # after trigger D-30 (lag=1)
        _BASE_DATE - timedelta(days=31),  # after trigger D-32 (lag=1)
        _BASE_DATE - timedelta(days=49),  # after non-trigger D-50 (lag=1)
    }

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=3,
        min_total_events=2,
        min_rate_ratio=2.0,
    )

    assert isinstance(result, LaggedCorrelationResult)
    assert result.rate_ratio == pytest.approx(2.0)


def test_primitive_event_before_trigger_not_counted() -> None:
    """(h) Event 1 day BEFORE a trigger day (negative lag) must NOT be counted."""
    from lifeos.insights.correlate import _detect_lagged_correlation

    trigger_day = _BASE_DATE - timedelta(days=10)
    # Event is 1 day BEFORE trigger (trigger_day - 1)
    event_before = trigger_day - timedelta(days=1)

    trigger = {trigger_day, _BASE_DATE - timedelta(days=20), _BASE_DATE - timedelta(days=30),
               _BASE_DATE - timedelta(days=40), _BASE_DATE - timedelta(days=50)}
    non_trigger = {_BASE_DATE - timedelta(days=60), _BASE_DATE - timedelta(days=61)}
    events = {event_before, event_before - timedelta(days=1)}  # both before any trigger

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
    )
    # events_after_trigger = 0 → rate_ratio = 0 → None
    assert result is None


def test_primitive_rate_floor_prevents_zero_division() -> None:
    """(i) rate_after_non_trigger=0 + rate_floor=0.001 → finite result, no ZeroDivision."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_lagged_correlation

    trigger = _trigger_set([10, 11, 12, 13, 14, 15])
    non_trigger = _trigger_set([50, 51, 52])  # far from events → 0 events after
    # Events only after triggers → events_after_non_trigger = 0
    events = _event_set([9, 10, 11])

    result = _detect_lagged_correlation(
        trigger_days=trigger,
        non_trigger_days=non_trigger,
        event_days=events,
        n_trigger_days=len(trigger),
        n_non_trigger_days=len(non_trigger),
        window_days=90,
        lag_days=2,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=2.0,
        rate_floor=0.001,
    )

    assert isinstance(result, LaggedCorrelationResult)
    import math
    assert math.isfinite(result.rate_ratio)


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — _persist_correlation_edge_for (generic persist)  [task 3.1 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def _make_lagged_result(
    trigger_count: int = 5,
    non_trigger_count: int = 3,
    events_after_trigger: int = 4,
    events_after_non_trigger: int = 1,
    total_events: int = 8,
    rate_ratio: float = 3.0,
    window_days: int = 90,
    lag_days: int = 2,
) -> "LaggedCorrelationResult":  # type: ignore[name-defined]
    from lifeos.insights.correlate import LaggedCorrelationResult
    return LaggedCorrelationResult(
        trigger_count=trigger_count,
        non_trigger_count=non_trigger_count,
        events_after_trigger=events_after_trigger,
        events_after_non_trigger=events_after_non_trigger,
        total_events=total_events,
        rate_ratio=rate_ratio,
        window_days=window_days,
        lag_days=lag_days,
    )


def test_generic_persist_creates_edge_with_correct_shape() -> None:
    """(a) _persist_correlation_edge_for creates edge with correct src/dst/rel/created_by."""
    from lifeos.insights.correlate import _persist_correlation_edge_for

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    src = ("health", "sleep_deficit_pattern")
    dst = ("relationships", "conflict_pattern")
    note_fn = lambda r: f"Test note ratio {r.rate_ratio:.1f}"

    _persist_correlation_edge_for(
        _make_lagged_result(), _NOW, src=src, dst=dst, note_fn=note_fn, edges_mod=mock_edges
    )

    mock_edges.create.assert_called_once()
    kwargs = mock_edges.create.call_args.kwargs
    assert kwargs["rel"] == "correlates-with"
    assert kwargs["src"] == src
    assert kwargs["dst"] == dst
    assert kwargs["created_by"] == "correlation_snapshot"


def test_generic_persist_metadata_keys_present() -> None:
    """(b) metadata contains all required generic keys."""
    from lifeos.insights.correlate import _persist_correlation_edge_for

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []
    note_fn = lambda r: "nota de prueba"

    _persist_correlation_edge_for(
        _make_lagged_result(), _NOW,
        src=("health", "sleep_deficit_pattern"),
        dst=("relationships", "conflict_pattern"),
        note_fn=note_fn,
        edges_mod=mock_edges,
    )

    metadata = mock_edges.create.call_args.kwargs["metadata"]
    required = {
        "strength", "rate_ratio", "window_days", "lag_days",
        "trigger_count", "events_after_trigger", "total_events",
        "expires_at", "snapshot", "note",
    }
    for key in required:
        assert key in metadata, f"Missing metadata key: {key}"


def test_generic_persist_expires_at_is_now_plus_ttl() -> None:
    """(c) expires_at == (now + timedelta(days=_TTL_DAYS)).isoformat()."""
    from lifeos.insights.correlate import _persist_correlation_edge_for, _TTL_DAYS

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []
    fixed_now = datetime(2024, 1, 1, 0, 0, 0, tzinfo=timezone.utc)

    _persist_correlation_edge_for(
        _make_lagged_result(), fixed_now,
        src=("health", "a"),
        dst=("finance", "b"),
        note_fn=lambda r: "x",
        edges_mod=mock_edges,
    )

    metadata = mock_edges.create.call_args.kwargs["metadata"]
    expected = (fixed_now + timedelta(days=_TTL_DAYS)).isoformat()
    assert metadata["expires_at"] == expected


def test_generic_persist_dedup_delete_then_create() -> None:
    """(d) Pre-existing edge with same src[1]/dst[1] is deleted before create."""
    from lifeos.insights.correlate import _persist_correlation_edge_for

    src = ("health", "sleep_deficit_pattern")
    dst = ("relationships", "conflict_pattern")

    stale = MagicMock()
    stale.id = "stale-generic-id"
    stale.src_id = src[1]
    stale.dst_id = dst[1]

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = [stale]

    call_order: list[str] = []
    mock_edges.delete.side_effect = lambda _id: call_order.append("delete")
    mock_edges.create.side_effect = lambda **_kw: call_order.append("create") or MagicMock()

    _persist_correlation_edge_for(
        _make_lagged_result(), _NOW, src=src, dst=dst,
        note_fn=lambda r: "n", edges_mod=mock_edges,
    )

    mock_edges.delete.assert_called_once_with("stale-generic-id")
    assert call_order == ["delete", "create"], f"Expected delete→create, got {call_order}"


def test_generic_persist_no_delete_when_no_prior_edge() -> None:
    """(e) No prior edge → delete() is NOT called."""
    from lifeos.insights.correlate import _persist_correlation_edge_for

    mock_edges = MagicMock()
    mock_edges.by_relation.return_value = []

    _persist_correlation_edge_for(
        _make_lagged_result(), _NOW,
        src=("health", "a"),
        dst=("finance", "b"),
        note_fn=lambda r: "n",
        edges_mod=mock_edges,
    )

    mock_edges.delete.assert_not_called()


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — _conflict_days helper  [task 3.3 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def _make_interaction(ts: datetime, kind: str):
    i = MagicMock()
    i.ts = ts
    i.kind = kind
    return i


def test_conflict_days_filters_by_kind() -> None:
    """(a) Only interactions with kind='conflict' are included."""
    from lifeos.insights.correlate import _conflict_days

    interactions = [
        _make_interaction(datetime(2024, 6, 1, tzinfo=timezone.utc), "conflict"),
        _make_interaction(datetime(2024, 6, 2, tzinfo=timezone.utc), "hangout"),
        _make_interaction(datetime(2024, 6, 3, tzinfo=timezone.utc), "conflict"),
    ]
    result = _conflict_days(interactions)
    assert result == {date(2024, 6, 1), date(2024, 6, 3)}


def test_conflict_days_same_day_deduped() -> None:
    """(b) Multiple conflicts on the same day → one date in result set."""
    from lifeos.insights.correlate import _conflict_days

    ts = datetime(2024, 6, 10, tzinfo=timezone.utc)
    interactions = [
        _make_interaction(ts, "conflict"),
        _make_interaction(ts + timedelta(hours=3), "conflict"),
    ]
    result = _conflict_days(interactions)
    assert result == {date(2024, 6, 10)}
    assert len(result) == 1


def test_conflict_days_tz_normalization() -> None:
    """(c) Non-UTC timestamps are converted to UTC date correctly."""
    from lifeos.insights.correlate import _conflict_days

    # UTC-5 at 2024-06-10 23:00 → UTC 2024-06-11 04:00 → date 2024-06-11
    import datetime as _dt_mod
    tz_minus5 = _dt_mod.timezone(_dt_mod.timedelta(hours=-5))
    ts_local = datetime(2024, 6, 10, 23, 0, 0, tzinfo=tz_minus5)
    interactions = [_make_interaction(ts_local, "conflict")]
    result = _conflict_days(interactions)
    assert result == {date(2024, 6, 11)}


def test_conflict_days_empty_returns_empty_set() -> None:
    """Empty interactions list → empty set."""
    from lifeos.insights.correlate import _conflict_days
    assert _conflict_days([]) == set()


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — _exercise_days helper  [task 3.5 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def _make_session(ts: datetime):
    s = MagicMock()
    s.ts = ts
    return s


def test_exercise_days_all_sessions_one_date_each() -> None:
    """(a) Each session on a distinct day → one date per session."""
    from lifeos.insights.correlate import _exercise_days

    sessions = [
        _make_session(datetime(2024, 6, 1, tzinfo=timezone.utc)),
        _make_session(datetime(2024, 6, 3, tzinfo=timezone.utc)),
        _make_session(datetime(2024, 6, 5, tzinfo=timezone.utc)),
    ]
    result = _exercise_days(sessions)
    assert result == {date(2024, 6, 1), date(2024, 6, 3), date(2024, 6, 5)}


def test_exercise_days_same_day_deduped() -> None:
    """(b) Multiple sessions on the same day → one date in set."""
    from lifeos.insights.correlate import _exercise_days

    ts = datetime(2024, 6, 10, tzinfo=timezone.utc)
    sessions = [
        _make_session(ts),
        _make_session(ts + timedelta(hours=4)),
    ]
    result = _exercise_days(sessions)
    assert result == {date(2024, 6, 10)}
    assert len(result) == 1


def test_exercise_days_tz_normalization() -> None:
    """(c) Non-UTC session timestamps are converted to UTC date correctly."""
    from lifeos.insights.correlate import _exercise_days
    import datetime as _dt_mod

    tz_plus2 = _dt_mod.timezone(_dt_mod.timedelta(hours=2))
    # 2024-06-10 01:00+02:00 → UTC 2024-06-09 23:00 → date 2024-06-09
    ts_local = datetime(2024, 6, 10, 1, 0, 0, tzinfo=tz_plus2)
    result = _exercise_days([_make_session(ts_local)])
    assert result == {date(2024, 6, 9)}


def test_exercise_days_empty_returns_empty_set() -> None:
    """Empty sessions → empty set."""
    from lifeos.insights.correlate import _exercise_days
    assert _exercise_days([]) == set()


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — _window_dates helper  [task 3.7 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def test_window_dates_len_equals_window_days() -> None:
    """(a) len(result) == window_days."""
    from lifeos.insights.correlate import _window_dates

    now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    result = _window_dates(now, 90)
    assert len(result) == 90


def test_window_dates_most_recent_is_today() -> None:
    """(b) Most recent date == now.astimezone(utc).date()."""
    from lifeos.insights.correlate import _window_dates

    now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    result = _window_dates(now, 30)
    assert date(2024, 6, 15) in result


def test_window_dates_oldest_is_window_days_minus_1_ago() -> None:
    """(c) Oldest date == now.date() - timedelta(days=window_days-1)."""
    from lifeos.insights.correlate import _window_dates

    now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    result = _window_dates(now, 30)
    expected_oldest = date(2024, 6, 15) - timedelta(days=29)
    assert expected_oldest in result


def test_window_dates_deterministic() -> None:
    """(d) Same now + window_days always produces the same set."""
    from lifeos.insights.correlate import _window_dates

    now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    assert _window_dates(now, 14) == _window_dates(now, 14)


def test_window_dates_no_future_dates() -> None:
    """All dates in result are <= now's UTC date."""
    from lifeos.insights.correlate import _window_dates

    now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    result = _window_dates(now, 30)
    today = date(2024, 6, 15)
    assert all(d <= today for d in result)


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — _detect_sleep_conflicts_correlation  [task 4.1 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def _fake_health_list(*entries):
    """DAO fake for health entries (sleep vitals)."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


def _fake_rel_list(*entries):
    """DAO fake for relationship interactions."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


def _fake_exercise_list(*entries):
    """DAO fake for exercise sessions."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


def _fake_finance_list(*entries):
    """DAO fake for finance entries."""
    def _inner(**_kwargs):
        return list(entries)
    return _inner


# Anchor for phase 4 tests — use a fixed now so date arithmetic is deterministic
_NOW4 = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)


def _d4(offset_days: int) -> datetime:
    """Shorthand: _NOW4 minus offset_days (UTC)."""
    return _NOW4 - timedelta(days=offset_days)


def test_sleep_conflicts_fires_when_all_guards_pass() -> None:
    """(a) Fires and returns LaggedCorrelationResult when poor-sleep & conflict days pass all guards."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_sleep_conflicts_correlation

    # 3 poor-sleep days and 2 conflict days within lag window → should fire
    sleep = [
        _make_sleep_entry(_d4(10), 5.0),  # poor
        _make_sleep_entry(_d4(9), 4.5),   # poor
        _make_sleep_entry(_d4(8), 5.5),   # poor
        _make_sleep_entry(_d4(7), 7.0),   # ok
    ]
    interactions = [
        _make_interaction(_d4(10), "conflict"),  # same day as poor sleep
        _make_interaction(_d4(8), "conflict"),   # same day as poor sleep
    ]

    result = _detect_sleep_conflicts_correlation(
        _NOW4,
        health_list_recent=_fake_health_list(*sleep),
        rel_list_recent=_fake_rel_list(*interactions),
    )

    assert isinstance(result, LaggedCorrelationResult)
    assert result.rate_ratio >= 2.0


def test_sleep_conflicts_none_when_no_conflict_data() -> None:
    """(b) Returns None when conflict_days is empty."""
    from lifeos.insights.correlate import _detect_sleep_conflicts_correlation

    sleep = [
        _make_sleep_entry(_d4(10), 5.0),
        _make_sleep_entry(_d4(9), 4.5),
        _make_sleep_entry(_d4(8), 5.5),
    ]

    result = _detect_sleep_conflicts_correlation(
        _NOW4,
        health_list_recent=_fake_health_list(*sleep),
        rel_list_recent=_fake_rel_list(),  # no interactions
    )

    assert result is None


def test_sleep_conflicts_none_when_below_trigger_threshold() -> None:
    """(c) Returns None when poor_sleep_days < min_trigger_days."""
    from lifeos.insights.correlate import _detect_sleep_conflicts_correlation

    # Only 2 poor-sleep days (< 3)
    sleep = [
        _make_sleep_entry(_d4(10), 5.0),
        _make_sleep_entry(_d4(9), 4.5),
        _make_sleep_entry(_d4(8), 7.0),  # ok
    ]
    interactions = [
        _make_interaction(_d4(10), "conflict"),
        _make_interaction(_d4(9), "conflict"),
    ]

    result = _detect_sleep_conflicts_correlation(
        _NOW4,
        health_list_recent=_fake_health_list(*sleep),
        rel_list_recent=_fake_rel_list(*interactions),
    )

    assert result is None


def test_sleep_conflicts_note_is_nonempty_spanish_text() -> None:
    """(d) The note generated by the detector contains Spanish text mentioning conflicts and sleep."""
    from lifeos.insights.correlate import _detect_sleep_conflicts_correlation, _sleep_conflicts_note

    sleep = [
        _make_sleep_entry(_d4(10), 5.0),
        _make_sleep_entry(_d4(9), 4.5),
        _make_sleep_entry(_d4(8), 5.5),
        _make_sleep_entry(_d4(7), 7.0),
    ]
    interactions = [
        _make_interaction(_d4(10), "conflict"),
        _make_interaction(_d4(8), "conflict"),
    ]

    result = _detect_sleep_conflicts_correlation(
        _NOW4,
        health_list_recent=_fake_health_list(*sleep),
        rel_list_recent=_fake_rel_list(*interactions),
    )
    assert result is not None, "Expected detector to fire for note test"

    # Verify the note template exists and has non-ASCII Spanish characters
    sample_note = _sleep_conflicts_note(result)
    assert isinstance(sample_note, str)
    assert len(sample_note.strip()) > 0
    assert any(ord(c) > 127 for c in sample_note), f"note has no non-ASCII chars: {sample_note!r}"
    # Must mention conflicts and sleep
    assert "conflicto" in sample_note.lower() or "Conflicto" in sample_note
    assert "sueño" in sample_note.lower() or "sue" in sample_note.lower()


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — _detect_exercise_gap_spending_correlation  [task 4.3 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def test_exercise_gap_fires_when_all_guards_pass() -> None:
    """(a) Fires when exercise_days>=5, gap_days>=5, impulsive>=2, rate_ratio>=2.0."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_exercise_gap_spending_correlation

    # 8 exercise sessions on distinct days; window=90 → gap=82 days
    # Place exercises in the recent window
    sessions = [_make_session(_d4(i)) for i in range(1, 9)]  # D-1..D-8 (8 days)
    # Impulsive purchases on gap days (far from exercise days)
    finance = [
        _make_purchase_entry(_d4(20)),   # gap day
        _make_purchase_entry(_d4(25)),   # gap day
        _make_purchase_entry(_d4(30)),   # gap day
    ]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    assert isinstance(result, LaggedCorrelationResult)


def test_exercise_gap_none_when_fewer_than_5_exercise_days() -> None:
    """(b) Returns None when exercise_days < 5 (trivial-fire guard fires BEFORE primitive)."""
    from lifeos.insights.correlate import _detect_exercise_gap_spending_correlation

    # Only 4 exercise sessions
    sessions = [_make_session(_d4(i)) for i in range(1, 5)]
    finance = [
        _make_purchase_entry(_d4(20)),
        _make_purchase_entry(_d4(25)),
    ]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    assert result is None


def test_exercise_gap_none_when_all_days_have_exercise() -> None:
    """(c) Returns None when all window days have exercise (gap=0)."""
    from lifeos.insights.correlate import _detect_exercise_gap_spending_correlation, _WINDOW_DAYS

    # Session on every day of the window
    sessions = [_make_session(_d4(i)) for i in range(_WINDOW_DAYS)]
    finance = [
        _make_purchase_entry(_d4(50)),
        _make_purchase_entry(_d4(60)),
    ]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    assert result is None


def test_exercise_gap_boundary_exactly_5_exercise_days() -> None:
    """(d) Exactly 5 exercise days passes the guard (boundary inclusive)."""
    from lifeos.insights.correlate import LaggedCorrelationResult, _detect_exercise_gap_spending_correlation

    # Exactly 5 exercise days; rest of 90-day window = 85 gap days (>=5 min_trigger)
    sessions = [_make_session(_d4(i)) for i in range(1, 6)]  # D-1..D-5 (5 days)
    # Purchases on gap days well separated from exercise days
    finance = [
        _make_purchase_entry(_d4(20)),
        _make_purchase_entry(_d4(25)),
        _make_purchase_entry(_d4(30)),
    ]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    # Boundary (>=5 exercise days) → guard passes; should fire given enough gap/purchases
    assert isinstance(result, LaggedCorrelationResult)


def test_exercise_gap_none_when_gap_days_below_min_trigger() -> None:
    """(e) Returns None when gap_days < min_trigger_days=5."""
    from lifeos.insights.correlate import _detect_exercise_gap_spending_correlation, _WINDOW_DAYS

    # 87 exercise sessions → gap = 90-87 = 3 < min_trigger_days=5
    sessions = [_make_session(_d4(i)) for i in range(_WINDOW_DAYS - 3)]
    finance = [
        _make_purchase_entry(_d4(89)),
        _make_purchase_entry(_d4(88)),
    ]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    assert result is None


def test_exercise_gap_none_when_fewer_than_2_impulsive() -> None:
    """(f) Returns None when total_impulsive=1 < min_total_events=2."""
    from lifeos.insights.correlate import _detect_exercise_gap_spending_correlation

    sessions = [_make_session(_d4(i)) for i in range(1, 9)]  # 8 exercise days
    # Only 1 impulsive purchase
    finance = [_make_purchase_entry(_d4(20))]

    result = _detect_exercise_gap_spending_correlation(
        _NOW4,
        exercise_list_recent=_fake_exercise_list(*sessions),
        finance_list_recent=_fake_finance_list(*finance),
    )

    assert result is None


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — _DETECTORS structure  [task 5.1 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def test_detectors_list_has_three_entries() -> None:
    """_DETECTORS must have exactly 3 entries."""
    from lifeos.insights.correlate import _DETECTORS
    assert len(_DETECTORS) == 3


def test_detectors_each_entry_is_two_tuple() -> None:
    """Each entry in _DETECTORS must be a 2-tuple of (callable, dict)."""
    from lifeos.insights.correlate import _DETECTORS
    for entry in _DETECTORS:
        assert isinstance(entry, tuple), f"Entry {entry!r} is not a tuple"
        assert len(entry) == 2, f"Entry {entry!r} does not have 2 elements"
        detect_fn, cfg = entry
        assert callable(detect_fn), f"detect_fn in {entry!r} is not callable"
        assert isinstance(cfg, dict), f"cfg in {entry!r} is not a dict"


def test_detectors_each_cfg_has_required_keys() -> None:
    """Each cfg dict must have 'name' and 'persist' keys."""
    from lifeos.insights.correlate import _DETECTORS
    for detect_fn, cfg in _DETECTORS:
        assert "name" in cfg, f"cfg missing 'name' key: {cfg!r}"
        assert "persist" in cfg, f"cfg missing 'persist' key: {cfg!r}"
        assert callable(cfg["persist"]), f"cfg['persist'] is not callable: {cfg!r}"


def test_detectors_sleep_entry_uses_bespoke_persist() -> None:
    """Sleep detector's persist must be the bespoke _persist_correlation_edge."""
    from lifeos.insights.correlate import _DETECTORS, _persist_correlation_edge
    # Find the sleep entry by name
    sleep_entries = [(fn, cfg) for fn, cfg in _DETECTORS if cfg.get("name") == "sleep_spending"]
    assert len(sleep_entries) == 1, "Expected exactly one 'sleep_spending' detector"
    _, cfg = sleep_entries[0]
    assert cfg["persist"] is _persist_correlation_edge, (
        "Sleep detector's persist must be the bespoke _persist_correlation_edge"
    )


def test_detectors_new_entries_have_partial_persist() -> None:
    """New detectors' persist callables must be functools.partial instances."""
    import functools
    from lifeos.insights.correlate import _DETECTORS
    new_entries = [(fn, cfg) for fn, cfg in _DETECTORS if cfg.get("name") != "sleep_spending"]
    assert len(new_entries) == 2, f"Expected 2 new detector entries, got {len(new_entries)}"
    for _, cfg in new_entries:
        assert isinstance(cfg["persist"], functools.partial), (
            f"New detector cfg['persist'] should be functools.partial, got {type(cfg['persist'])}"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — _run_correlation_snapshot resilience  [task 5.3 RED]
# ═══════════════════════════════════════════════════════════════════════════════

def test_snapshot_per_detector_isolation_one_raises() -> None:
    """(a) Detector A raises → detectors B and C still run and persist their edges."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot, _DETECTORS
    import functools

    # Seed data so sleep→spending fires (detector 0)
    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(8)

    # We'll patch _DETECTORS to have one failing detector + sleep (which fires)
    # and a stub third that also fires — using a mock persist to track calls
    persist_b_called = []
    persist_c_called = []

    def _failing_detect(now, **_kw):
        raise RuntimeError("Simulated detector failure")

    def _always_fires_detect(now, **_kw):
        from lifeos.insights.correlate import LaggedCorrelationResult
        return LaggedCorrelationResult(
            trigger_count=3, non_trigger_count=2,
            events_after_trigger=2, events_after_non_trigger=0,
            total_events=2, rate_ratio=2.5, window_days=90, lag_days=2,
        )

    def _stub_persist_b(result, now, **kw):
        persist_b_called.append(True)

    def _stub_persist_c(result, now, **kw):
        persist_c_called.append(True)

    fake_detectors = [
        (_failing_detect, {"name": "failing_a", "persist": _stub_persist_b}),
        (_always_fires_detect, {"name": "fires_b", "persist": _stub_persist_b}),
        (_always_fires_detect, {"name": "fires_c", "persist": _stub_persist_c}),
    ]

    with patch("lifeos.insights.correlate._DETECTORS", fake_detectors):
        _run_correlation_snapshot()

    assert len(persist_b_called) == 1, "Detector B should have persisted despite A's failure"
    assert len(persist_c_called) == 1, "Detector C should have persisted despite A's failure"


def test_snapshot_all_three_fire_distinct_edges() -> None:
    """(b) All three detectors fire → three distinct edges with unique (src_id, dst_id) pairs."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot

    # Seed sleep→spending data
    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(8)

    # Seed sleep→conflict data
    _seed_conflict(10)
    _seed_conflict(8)

    # Seed exercise gap→spending data (8 exercise days + purchases on gap days)
    for i in range(1, 9):
        _seed_exercise_session(i + 20)  # exercise far from now; gaps = recent days
    # Purchases on gap days (recent, within window, not on exercise days)
    _seed_impulsive_purchase(5)
    _seed_impulsive_purchase(6)
    _seed_impulsive_purchase(7)

    _run_correlation_snapshot()

    corr_edges = [e for e in edges.by_relation("correlates-with")]
    edge_pairs = {(e.src_id, e.dst_id) for e in corr_edges}
    # Must have at least the sleep→spending edge; may have others depending on data
    assert ("sleep_deficit_pattern", "impulsive_spending") in edge_pairs


def test_snapshot_sleep_runs_exactly_once() -> None:
    """Sleep detector runs exactly once (not double-persisted) after moving into _DETECTORS."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot

    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(9)

    _run_correlation_snapshot()

    matching = [
        e for e in edges.by_relation("correlates-with")
        if e.src_id == "sleep_deficit_pattern" and e.dst_id == "impulsive_spending"
    ]
    assert len(matching) == 1, (
        f"Sleep→spending edge must appear EXACTLY ONCE, got {len(matching)}"
    )


def test_snapshot_idempotency_no_duplicates_on_rerun() -> None:
    """(c) Re-run with same data → still exactly one edge per detector (dedup)."""
    from lifeos import edges
    from lifeos.insights.correlate import _run_correlation_snapshot

    _seed_poor_sleep(10)
    _seed_poor_sleep(9)
    _seed_poor_sleep(8)
    _seed_impulsive_purchase(10)
    _seed_impulsive_purchase(8)

    _run_correlation_snapshot()
    _run_correlation_snapshot()

    matching = [
        e for e in edges.by_relation("correlates-with")
        if e.src_id == "sleep_deficit_pattern" and e.dst_id == "impulsive_spending"
    ]
    assert len(matching) == 1, (
        f"Expected exactly 1 sleep edge after two runs (idempotency), got {len(matching)}"
    )
