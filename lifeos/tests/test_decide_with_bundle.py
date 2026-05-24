"""Tests for decide/purchase.py and decide/symptom.py with CorrelationBundle."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos import store as core_store
    from lifeos.finance import store as fin_store
    from lifeos.health import store as hel_store
    core_store.apply_migrations()
    fin_store.apply_migrations()
    hel_store.apply_migrations()
    yield


# ─── purchase.build_prompt with bundle ───────────────────────────────────────

def test_purchase_prompt_without_bundle_has_no_context_section() -> None:
    from lifeos.decide.purchase import gather_context, build_prompt

    ctx = gather_context("laptop")
    prompt = build_prompt(ctx, bundle=None)
    assert "=== Contexto de vida actual ===" not in prompt


def test_purchase_prompt_with_empty_bundle_has_no_context_section() -> None:
    """Bundle with no patterns and no edges → edge_summary is '' → no injection."""
    from lifeos.insights.correlate import CorrelationBundle
    from lifeos.decide.purchase import gather_context, build_prompt

    bundle = CorrelationBundle(active_patterns=[], relevant_edges=[], edge_summary="")
    ctx = gather_context("laptop")
    prompt = build_prompt(ctx, bundle=bundle)
    assert "=== Contexto de vida actual ===" not in prompt


def test_purchase_prompt_with_active_bundle_injects_context() -> None:
    """Bundle with a non-empty edge_summary → injected section in prompt."""
    from lifeos.insights.correlate import CorrelationBundle
    from lifeos.decide.purchase import gather_context, build_prompt

    bundle = CorrelationBundle(
        active_patterns=[],
        relevant_edges=[],
        edge_summary="Contexto de vida actual:\n- Patrones activos:\n  · Dormís poco (sleep_deficit, severidad: warning)",
    )
    ctx = gather_context("laptop")
    prompt = build_prompt(ctx, bundle=bundle)
    assert "=== Contexto de vida actual ===" in prompt
    assert "sleep_deficit" in prompt
    assert "===============================" in prompt


def test_purchase_consult_with_bundle_reaches_brain() -> None:
    """End-to-end: consult() with bundle passes context-enriched prompt to brain."""
    from lifeos.insights.correlate import CorrelationBundle
    from lifeos.decide.purchase import consult

    bundle = CorrelationBundle(
        active_patterns=[],
        relevant_edges=[],
        edge_summary="Contexto de vida actual:\n- Patrones activos:\n  · Dormís 5.4h (sleep_deficit, severidad: warning)",
    )

    captured: list[str] = []

    def fake_brain(prompt: str, **_kw) -> str:
        captured.append(prompt)
        return "Recomendación: ESPERAR."

    result = consult("laptop gaming", brain_ask=fake_brain, bundle=bundle)
    assert "ESPERAR" in result.answer
    assert "=== Contexto de vida actual ===" in captured[0]
    assert "sleep_deficit" in captured[0]


def test_purchase_consult_without_bundle_no_context_in_prompt() -> None:
    from lifeos.decide.purchase import consult

    captured: list[str] = []

    def fake_brain(prompt: str, **_kw) -> str:
        captured.append(prompt)
        return "Recomendación: SÍ."

    consult("auriculares", brain_ask=fake_brain, bundle=None)
    assert "=== Contexto de vida actual ===" not in captured[0]


# ─── symptom.summarize with bundle ────────────────────────────────────────────

def test_symptom_summarize_without_bundle_no_context_section() -> None:
    from lifeos.health import entries
    from lifeos.decide.symptom import find_recurrences, summarize

    now = datetime.now(timezone.utc)
    entry = entries.create(kind="symptom", title="dolor garganta", when=now,
                           data={"location": "garganta"})
    # Create a past recurrence to get a non-None summary
    past = now.replace(year=now.year - 1)
    entries.create(kind="symptom", title="dolor garganta", when=past,
                   data={"location": "garganta"})

    recurrences = find_recurrences(entry)
    msg = summarize(entry, recurrences, bundle=None)
    if msg:
        assert "=== Contexto de vida actual ===" not in msg


def test_symptom_summarize_with_bundle_injects_context() -> None:
    from lifeos.health import entries
    from lifeos.decide.symptom import find_recurrences, summarize
    from lifeos.insights.correlate import CorrelationBundle

    now = datetime.now(timezone.utc)
    entry = entries.create(kind="symptom", title="dolor garganta", when=now,
                           data={"location": "garganta"})
    past = now.replace(year=now.year - 1)
    entries.create(kind="symptom", title="dolor garganta", when=past,
                   data={"location": "garganta"})

    bundle = CorrelationBundle(
        active_patterns=[],
        relevant_edges=[],
        edge_summary="Contexto de vida actual:\n- Patrones activos:\n  · Dormís poco",
    )
    recurrences = find_recurrences(entry)
    msg = summarize(entry, recurrences, bundle=bundle)
    if msg:
        assert "=== Contexto de vida actual ===" in msg
        assert "Dormís poco" in msg
