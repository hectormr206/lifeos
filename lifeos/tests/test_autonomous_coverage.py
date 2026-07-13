"""Tests for lifeos.autonomous.coverage — domain-coverage gap detection.

Strict TDD: these tests define the contract for coverage_gaps() before the
module exists. Domain stores are monkeypatched — no real DB is touched.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

MX = ZoneInfo("America/Mexico_City")


def _now() -> datetime:
    return datetime(2026, 6, 10, 12, 0, tzinfo=MX)


# Maps the 7 domain keys to (module import path, function name) that
# coverage.py probes. Kept here so the test asserts the real wiring.
_DOMAIN_MODULES = {
    "health": ("lifeos.health.entries", "list_recent"),
    "finance": ("lifeos.finance.entries", "list_recent"),
    "exercise": ("lifeos.exercise.sessions", "list_recent"),
    "relationships": ("lifeos.relationships.interactions", "list_recent"),
    "learning": ("lifeos.learning.entries", "list_recent"),
    "spirituality": ("lifeos.spirituality.entries", "list_recent"),
    "events": ("lifeos.events.entries", "list_recent"),
}


def _mk(state: str):
    """Build a fake list_recent for a given state."""
    if state == "recent":
        return lambda *a, **k: [object()]
    if state == "error":
        def _raise(*a, **k):
            raise RuntimeError("store down")
        return _raise
    return lambda *a, **k: []  # empty


def _patch_domains(monkeypatch: pytest.MonkeyPatch, states: dict[str, str]) -> None:
    """Patch every domain's list_recent according to `states` (default empty)."""
    import importlib
    for domain, (mod_path, fn_name) in _DOMAIN_MODULES.items():
        mod = importlib.import_module(mod_path)
        monkeypatch.setattr(mod, fn_name, _mk(states.get(domain, "empty")))


def test_coverage_gaps_all_empty_returns_all_in_order(monkeypatch: pytest.MonkeyPatch) -> None:
    """No domain has recent data → every domain is a gap, in deterministic order."""
    from lifeos.autonomous import coverage
    _patch_domains(monkeypatch, {})
    gaps = coverage.coverage_gaps(stale_days=14, now=_now())
    assert gaps == [
        "health", "finance", "exercise", "relationships",
        "learning", "spirituality", "events",
    ]


def test_coverage_gaps_recent_domain_not_a_gap(monkeypatch: pytest.MonkeyPatch) -> None:
    """A domain with a recent entry is NOT reported as a gap."""
    from lifeos.autonomous import coverage
    _patch_domains(monkeypatch, {"exercise": "recent", "health": "recent"})
    gaps = coverage.coverage_gaps(stale_days=14, now=_now())
    assert "exercise" not in gaps
    assert "health" not in gaps
    assert "finance" in gaps


def test_coverage_gaps_broken_store_is_not_a_gap(monkeypatch: pytest.MonkeyPatch) -> None:
    """A domain whose store raises is treated as UNKNOWN, never fabricated as a gap."""
    from lifeos.autonomous import coverage
    _patch_domains(monkeypatch, {"finance": "error", "health": "recent", "learning": "empty"})
    gaps = coverage.coverage_gaps(stale_days=14, now=_now())
    assert "finance" not in gaps      # broken → unknown, not a gap
    assert "health" not in gaps       # recent → not a gap
    assert "learning" in gaps         # genuinely empty → gap


def test_coverage_gaps_empty_when_all_recent(monkeypatch: pytest.MonkeyPatch) -> None:
    """All domains have recent data → no gaps."""
    from lifeos.autonomous import coverage
    _patch_domains(monkeypatch, {d: "recent" for d in _DOMAIN_MODULES})
    gaps = coverage.coverage_gaps(stale_days=14, now=_now())
    assert gaps == []
