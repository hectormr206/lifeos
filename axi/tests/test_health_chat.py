"""Tests for the SALUD (health) specialized chat — Slice 1.

The module classifies+extracts a health message in ONE 4B call (thinking OFF)
and dispatches to register / query / off_topic. The brain is ALWAYS mocked here
(scripted JSON for the extract step, scripted prose for the query step) so no
test ever hits the real llama-server. The health store is the per-test temp DB
provided by conftest's fresh_db fixture — never the real ~/.local/state DBs.
"""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from axi import health_chat
from lifeos.health import entries as health_entries

# A fixed "now" so date resolution is deterministic. System date is 2026-06-26.
TZ = ZoneInfo("America/Mexico_City")
NOW = datetime(2026, 6, 26, 12, 0, tzinfo=TZ)


def _extract(**fields) -> str:
    """Build a scripted extraction JSON payload with sensible null defaults."""
    base = {
        "intent": "off_topic",
        "kind": None,
        "systolic": None,
        "diastolic": None,
        "pulse_bpm": None,
        "glucose_mg_dl": None,
        "weight_kg": None,
        "sleep_hours": None,
        "title": None,
    }
    base.update(fields)
    return json.dumps(base)


def _fake_brain(extract_json: str, query_answer: str = "respuesta de salud",
                capture: list | None = None):
    """Return a brain_ask stub.

    think=False  → extract step → returns scripted JSON.
    think=True   → query step   → returns scripted prose.
    Every call is recorded in `capture` when provided.
    """
    def _ask(prompt, **kw):
        if capture is not None:
            capture.append({"prompt": prompt, **kw})
        if kw.get("think"):
            return query_answer
        return extract_json
    return _ask


# ─── register ──────────────────────────────────────────────────────────────


def test_register_blood_pressure_and_glucose_creates_vitals():
    extract = _extract(
        intent="register", kind="vital",
        systolic=120, diastolic=80, glucose_mg_dl=90, title="presión y glucosa",
    )
    res = health_chat.handle_health_message(
        "mi presión está en 120/80 y la glucosa en 90",
        now=NOW, brain_ask=_fake_brain(extract),
    )
    assert res["mode"] == "register"
    assert len(res["entry_ids"]) == 2
    assert "Salud" in res["answer"]

    recent = health_entries.list_recent(days=7)
    by_type = {e.data.get("type"): e for e in recent if e.kind == "vital"}
    assert "blood_pressure" in by_type
    assert "glucose" in by_type
    bp = by_type["blood_pressure"]
    assert bp.data["systolic"] == 120
    assert bp.data["diastolic"] == 80
    assert bp.data["unit"] == "mmHg"
    assert by_type["glucose"].data["value"] == 90


def test_register_sleep_creates_sleep_vital():
    extract = _extract(intent="register", kind="vital", sleep_hours=7.5, title="dormí")
    res = health_chat.handle_health_message(
        "dormí 7.5 horas", now=NOW, brain_ask=_fake_brain(extract),
    )
    assert res["mode"] == "register"
    recent = health_entries.list_recent(days=7)
    sleep = [e for e in recent if e.data.get("type") == "sleep_hours"]
    assert len(sleep) == 1
    assert sleep[0].data["value"] == 7.5
    assert sleep[0].data["unit"] == "h"


def test_register_falls_back_to_note_when_no_vitals():
    extract = _extract(intent="register", kind="note", title="me duele la cabeza")
    res = health_chat.handle_health_message(
        "me duele la cabeza desde la mañana", now=NOW, brain_ask=_fake_brain(extract),
    )
    assert res["mode"] == "register"
    assert res["entry_ids"]
    recent = health_entries.list_recent(days=7)
    assert any(e.kind in ("note", "symptom") for e in recent)


# ─── off_topic ─────────────────────────────────────────────────────────────


def test_off_topic_saves_nothing():
    extract = _extract(intent="off_topic")
    res = health_chat.handle_health_message(
        "gasté 200 pesos en el súper", now=NOW, brain_ask=_fake_brain(extract),
    )
    assert res["mode"] == "off_topic"
    assert "Salud" in res["answer"]
    # NOTHING persisted.
    assert health_entries.list_recent(days=365) == []


# ─── query ─────────────────────────────────────────────────────────────────


def test_query_consults_recent_and_passes_today_and_records(monkeypatch):
    captured: list = []
    crafted = [
        health_entries.Entry(
            id="01AAA", ts=datetime(2025, 12, 10, 8, 0, tzinfo=ZoneInfo("UTC")),
            kind="medication", title="paracetamol",
            body=None, data={"name": "paracetamol"},
        ),
    ]
    list_calls: list = []

    def _spy_list_recent(*, days=30, kind=None, limit=200):
        list_calls.append({"days": days, "kind": kind})
        return crafted

    monkeypatch.setattr(health_chat.health_entries, "list_recent", _spy_list_recent)

    extract = _extract(intent="query", title="qué tomé en diciembre")
    res = health_chat.handle_health_message(
        "qué tomé para la gripa de diciembre",
        now=NOW, brain_ask=_fake_brain(extract, capture=captured),
    )
    assert res["mode"] == "query"
    assert res["answer"] == "respuesta de salud"
    # list_recent was consulted.
    assert list_calls, "list_recent must be consulted on a query"
    # The SECOND (think=True) call is the query call; its system prompt must
    # carry today's date AND the loaded records.
    query_calls = [c for c in captured if c.get("think")]
    assert len(query_calls) == 1
    qsys = query_calls[0]["system"]
    assert "2026" in qsys                 # today's year for date disambiguation
    assert "paracetamol" in qsys          # the loaded record is in context
    assert "01AAA" in qsys                # entry id passed


def test_query_is_date_aware_for_relative_december(monkeypatch):
    """With now fixed at 2026-06-26, the query prompt must anchor 'today' to
    2026 so the brain resolves 'diciembre' to the most recent December (2025)."""
    captured: list = []
    monkeypatch.setattr(
        health_chat.health_entries, "list_recent",
        lambda **kw: [],
    )
    extract = _extract(intent="query")
    health_chat.handle_health_message(
        "qué tomé para la gripa de diciembre",
        now=NOW, brain_ask=_fake_brain(extract, capture=captured),
    )
    qsys = [c for c in captured if c.get("think")][0]["system"]
    assert "2026-06-26" in qsys
    # The brain is instructed to resolve relative months against today.
    assert "diciembre" in qsys.lower() or "december" in qsys.lower()


# ─── error path ────────────────────────────────────────────────────────────


def test_garbage_json_handled_and_saves_nothing():
    res = health_chat.handle_health_message(
        "presión 120/80", now=NOW,
        brain_ask=lambda prompt, **kw: "no soy json {esto está roto",
    )
    assert res["mode"] == "error"
    assert isinstance(res["answer"], str) and res["answer"]
    assert health_entries.list_recent(days=365) == []


def test_brain_exception_never_raises():
    def _boom(prompt, **kw):
        raise RuntimeError("brain down")

    res = health_chat.handle_health_message("presión 120/80", now=NOW, brain_ask=_boom)
    assert res["mode"] == "error"
    assert health_entries.list_recent(days=365) == []


def test_json_with_code_fences_is_parsed():
    fenced = "```json\n" + _extract(intent="off_topic") + "\n```"
    res = health_chat.handle_health_message(
        "esto no es salud", now=NOW, brain_ask=lambda prompt, **kw: fenced,
    )
    assert res["mode"] == "off_topic"


# ─── endpoint: POST /api/health/chat ────────────────────────────────────────


@pytest.fixture
def client(monkeypatch):
    from fastapi.testclient import TestClient
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def test_endpoint_register_returns_shape_and_persists(client, monkeypatch):
    from axi import brain
    extract = _extract(intent="register", kind="vital", systolic=120, diastolic=80,
                       title="presión")
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: extract)

    r = client.post("/api/health/chat", json={"text": "mi presión 120/80"})
    assert r.status_code == 200
    body = r.json()
    assert body["mode"] == "register"
    assert body["entry_ids"]
    assert "Salud" in body["answer"]
    assert isinstance(body["latency_ms"], int)
    # The vital is really in the (temp) health store.
    recent = health_entries.list_recent(days=7)
    assert any(e.data.get("type") == "blood_pressure" for e in recent)


def test_endpoint_off_topic_saves_nothing(client, monkeypatch):
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: _extract(intent="off_topic"))
    r = client.post("/api/health/chat", json={"text": "pagué la renta"})
    assert r.status_code == 200
    assert r.json()["mode"] == "off_topic"
    assert health_entries.list_recent(days=365) == []


def test_endpoint_rejects_empty(client):
    r = client.post("/api/health/chat", json={"text": "   "})
    assert r.status_code == 400


def test_endpoint_persists_turn_to_history(client, monkeypatch):
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: _extract(intent="off_topic"))
    client.post("/api/health/chat", json={"text": "esto no es salud"})
    r = client.get("/api/chat/history?limit=50")
    assert r.status_code == 200
    rows = r.json()
    assert rows and rows[-1]["user_text"] == "esto no es salud"


def test_chat_ask_still_works_unchanged(client, monkeypatch):
    """The general assistant endpoint must be untouched by this slice."""
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "respuesta general")
    monkeypatch.setattr(brain, "ask_with_tools", lambda prompt, **kw: "respuesta general")
    r = client.post("/api/chat/ask", json={"text": "hola"})
    assert r.status_code == 200
    assert r.json()["answer"] == "respuesta general"


def test_salud_page_renders(client):
    r = client.get("/chat/salud")
    assert r.status_code == 200
    assert "Salud" in r.text
