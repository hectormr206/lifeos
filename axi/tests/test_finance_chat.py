"""FINANZAS domain chat — proves the generic engine drives a second domain
(different store signature) from config alone."""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from axi import domain_chat, finance_chat
from axi.finance_chat import FINANCE_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Entry:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _fake_brain(extract_json, capture=None):
    def _ask(text, *, system=None, think=False, max_tokens=0):
        if capture is not None:
            capture.append({"think": think, "system": system})
        return "respuesta de finanzas" if think else extract_json
    return _ask


def _extract(**fields):
    import json
    base = {
        "intent": None, "kind": None, "amount": None, "currency": None,
        "category": None, "merchant": None, "title": None,
    }
    base.update(fields)
    return json.dumps(base)


def _patch_store(monkeypatch, *, recent=None):
    created: list = []
    monkeypatch.setattr(
        finance_chat.finance_entries, "create",
        lambda **kw: created.append(kw) or _Entry(id="F1", **kw),
    )
    monkeypatch.setattr(
        finance_chat.finance_entries, "list_recent",
        lambda **kw: (recent or []),
    )
    return created


def test_register_expense(monkeypatch):
    created = _patch_store(monkeypatch)
    res = domain_chat.handle_message(
        FINANCE_SPEC, "gasté 200 en el súper", now=NOW,
        brain_ask=_fake_brain(_extract(
            intent="register", kind="expense", amount=200,
            currency="MXN", category="comida", title="súper")),
    )
    assert res["mode"] == "register"
    assert "Finanzas" in res["answer"]
    assert len(created) == 1
    assert created[0]["kind"] == "expense"
    assert created[0]["amount"] == 200.0
    assert created[0]["currency"] == "MXN"


def test_register_income(monkeypatch):
    created = _patch_store(monkeypatch)
    res = domain_chat.handle_message(
        FINANCE_SPEC, "me pagaron 15000 de sueldo", now=NOW,
        brain_ask=_fake_brain(_extract(
            intent="register", kind="income", amount=15000, title="sueldo")),
    )
    assert res["mode"] == "register"
    assert created[0]["kind"] == "income"
    assert created[0]["amount"] == 15000.0


def test_amountless_message_kept_as_note(monkeypatch):
    created = _patch_store(monkeypatch)
    res = domain_chat.handle_message(
        FINANCE_SPEC, "tengo que revisar mis gastos", now=NOW,
        brain_ask=_fake_brain(_extract(intent="register", title="revisar gastos")),
    )
    assert res["mode"] == "register"
    assert created[0]["kind"] == "note"  # nothing lost


def test_query_passes_today_and_records(monkeypatch):
    capture: list = []
    recent = [_Entry(
        id="F9", ts=datetime(2025, 12, 5, tzinfo=ZoneInfo("UTC")),
        kind="expense", title="cena", amount=350.0, currency="MXN", category="comida")]
    _patch_store(monkeypatch, recent=recent)
    res = domain_chat.handle_message(
        FINANCE_SPEC, "cuánto gasté en diciembre", now=NOW,
        brain_ask=_fake_brain(_extract(intent="query"), capture=capture),
    )
    assert res["mode"] == "query"
    qsys = [c for c in capture if c["think"]][0]["system"]
    assert "2026" in qsys           # today's year for date disambiguation
    assert "F9" in qsys             # record id present
    assert "350" in qsys            # amount present
    assert "comida" in qsys         # category present


def test_query_falls_back_to_think_false_when_empty(monkeypatch):
    """think=True can burn the token budget reasoning and return empty. The
    query must retry with think=False rather than show a blank answer."""
    _patch_store(monkeypatch, recent=[])
    calls: list[bool] = []

    def _brain(text, *, system=None, think=False, max_tokens=0):
        calls.append(think)
        if not think and len(calls) == 1:
            return _extract(intent="query")   # step 1: classify+extract
        if think:
            return ""                          # primary query: budget exhausted
        return "respuesta sin pensar"          # fallback query (think=False)

    res = domain_chat.handle_message(FINANCE_SPEC, "cuánto gasté", now=NOW, brain_ask=_brain)
    assert res["mode"] == "query"
    assert res["answer"] == "respuesta sin pensar"
    assert True in calls and calls.count(False) >= 2  # primary think + fallback no-think


def test_off_topic_saves_nothing(monkeypatch):
    created = _patch_store(monkeypatch)
    res = domain_chat.handle_message(
        FINANCE_SPEC, "hoy medité 20 minutos", now=NOW,
        brain_ask=_fake_brain(_extract(intent="off_topic")),
    )
    assert res["mode"] == "off_topic"
    assert "Finanzas" in res["answer"]
    assert created == []
