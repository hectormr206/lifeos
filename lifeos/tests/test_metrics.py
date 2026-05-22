"""Tests for the fast-path metrics DAO."""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_record_and_list_roundtrip() -> None:
    from lifeos import metrics
    metrics.record(stage="health", latency_ms=42, text_length=80, has_image=False)
    metrics.record(stage="finance", latency_ms=18, text_length=30, has_image=False)
    rows = metrics.list_recent(days=1, limit=10)
    assert len(rows) == 2
    stages = {r.stage for r in rows}
    assert stages == {"health", "finance"}


def test_record_never_raises_on_bad_input() -> None:
    """record() is wrapped in try/except — never blocks the chat call."""
    from lifeos import metrics
    metrics.record(stage="weird-but-string", latency_ms=10, text_length=0)
    metrics.record(stage="brain", latency_ms=0, text_length=0)  # zero latency OK
    rows = metrics.list_recent(days=1, limit=10)
    assert len(rows) == 2


def test_summary_empty_returns_zeros() -> None:
    from lifeos import metrics
    s = metrics.summary(days=7)
    assert s["total"] == 0
    assert s["brain_fallback_pct"] == 0.0
    assert s["by_stage"] == []


def test_summary_counts_and_percentages() -> None:
    from lifeos import metrics
    # 5 brain calls + 3 finance + 2 health = 10 total
    for _ in range(5):
        metrics.record(stage="brain", latency_ms=2000, text_length=100)
    for _ in range(3):
        metrics.record(stage="finance", latency_ms=20, text_length=40)
    for _ in range(2):
        metrics.record(stage="health", latency_ms=15, text_length=30)

    s = metrics.summary(days=7)
    assert s["total"] == 10
    assert s["brain_fallback_pct"] == 50.0    # 5/10
    by_stage = {r["stage"]: r for r in s["by_stage"]}
    assert by_stage["brain"]["count"] == 5
    assert by_stage["brain"]["pct"] == 50.0
    assert by_stage["finance"]["count"] == 3
    assert by_stage["finance"]["pct"] == 30.0
    assert by_stage["health"]["count"] == 2
    assert by_stage["health"]["pct"] == 20.0


def test_summary_latency_stats() -> None:
    from lifeos import metrics
    # 10 brain calls with known latencies
    for l in (100, 200, 300, 400, 500, 600, 700, 800, 900, 1000):
        metrics.record(stage="brain", latency_ms=l, text_length=10)
    s = metrics.summary(days=7)
    brain_stats = s["by_stage"][0]
    assert brain_stats["stage"] == "brain"
    assert brain_stats["latency_ms_p50"] == 550        # median of 1..10 *100
    # p95 = 950 (with linear interpolation)
    assert 900 <= brain_stats["latency_ms_p95"] <= 1000
    assert brain_stats["latency_ms_mean"] == 550


def test_summary_sorted_by_count_desc() -> None:
    from lifeos import metrics
    for _ in range(2):
        metrics.record(stage="A", latency_ms=10, text_length=0)
    for _ in range(5):
        metrics.record(stage="B", latency_ms=10, text_length=0)
    for _ in range(1):
        metrics.record(stage="C", latency_ms=10, text_length=0)

    s = metrics.summary(days=7)
    assert [r["stage"] for r in s["by_stage"]] == ["B", "A", "C"]


def test_clear_wipes_table() -> None:
    from lifeos import metrics
    metrics.record(stage="x", latency_ms=10, text_length=0)
    metrics.record(stage="y", latency_ms=10, text_length=0)
    assert len(metrics.list_recent(days=1)) == 2
    metrics.clear()
    assert metrics.list_recent(days=1) == []
