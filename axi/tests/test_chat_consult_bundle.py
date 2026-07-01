"""The live chat decision paths must inject the correlation bundle.

The Correlation Engine builds a CorrelationBundle (active patterns + relevant
graph edges) that decision engines inject into their prompts. These tests pin
the *last mile*: the dashboard chat handler must call ``build_bundle()`` and
pass the result into ``purchase.consult`` and ``symptom.summarize``. Without
this wiring the bundle only feeds the read-only ``/api/insights/context`` card
and never reaches a real decision.

We monkeypatch the engines with spies that capture the ``bundle`` kwarg so we
assert on the wiring, not on the brain.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from lifeos.decide.purchase import PurchaseConsultResult, PurchaseContext
from lifeos.insights.correlate import CorrelationBundle


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def test_purchase_consult_receives_correlation_bundle(client, monkeypatch):
    from axi import dashboard
    from axi import brain

    captured = {}

    def spy_consult(item, *, brain_ask, language, bundle=None, **kw):
        captured["bundle"] = bundle
        return PurchaseConsultResult(answer="ok", context=PurchaseContext())

    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "no debería llamarse")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **kw: "no debería llamarse")
    monkeypatch.setattr(dashboard.decide_purchase, "consult", spy_consult)

    r = client.post("/api/chat/ask", json={"text": "¿puedo comprar una laptop?"})
    assert r.status_code == 200

    assert "bundle" in captured, "consult() was never called via the purchase fast-path"
    assert isinstance(captured["bundle"], CorrelationBundle), (
        "purchase consult must receive a CorrelationBundle, got "
        f"{type(captured['bundle']).__name__}"
    )


def test_symptom_summarize_receives_correlation_bundle(client, monkeypatch):
    from axi import dashboard

    captured = {}

    def spy_summarize(entry, recurrences, *, language=None, bundle=None, **kw):
        captured["bundle"] = bundle
        return ""

    # Keep the symptom branch deterministic: no DB lookups, force the spy.
    monkeypatch.setattr(dashboard.decide_symptom, "find_recurrences", lambda entry: [])
    monkeypatch.setattr(dashboard.decide_symptom, "summarize", spy_summarize)

    r = client.post("/api/chat/ask", json={"text": "me duele la cabeza"})
    assert r.status_code == 200

    assert "bundle" in captured, (
        "summarize() was never called — 'me duele la cabeza' did not reach the "
        "symptom surfacer; adjust the trigger text if parse_health changed"
    )
    assert isinstance(captured["bundle"], CorrelationBundle), (
        "symptom summarize must receive a CorrelationBundle, got "
        f"{type(captured['bundle']).__name__}"
    )
