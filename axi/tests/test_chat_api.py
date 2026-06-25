"""Tests for the in-dashboard text chat (P-chat).

The chat endpoints share the same ConversationMemory as the daemon's voice
path. We monkeypatch `brain.ask` to avoid hitting llama-server.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    # Reset the singleton so every test gets a memory bound to the fresh DB
    # provided by the conftest fixture.
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def test_chat_ask_returns_answer(client, monkeypatch):
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "respuesta de prueba")
    monkeypatch.setattr(brain, "ask_with_tools", lambda prompt, **kw: "respuesta de prueba")

    r = client.post("/api/chat/ask", json={"text": "hola"})
    assert r.status_code == 200
    body = r.json()
    assert body["answer"] == "respuesta de prueba"
    assert isinstance(body["latency_ms"], int)
    assert body["latency_ms"] >= 0


def test_chat_ask_passes_history(client, monkeypatch):
    """The brain call must receive the prior turns as `history`."""
    from axi import brain, store

    # Seed two prior turns directly through the store.
    store.add_conversation("primera pregunta", "primera respuesta")
    store.add_conversation("segunda pregunta", "segunda respuesta")

    captured: dict = {}

    def fake_ask(prompt, **kw):
        captured["prompt"] = prompt
        captured["history"] = kw.get("history")
        return "ok"

    monkeypatch.setattr(brain, "ask", fake_ask)
    monkeypatch.setattr(brain, "ask_with_tools", fake_ask)

    r = client.post("/api/chat/ask", json={"text": "tercera"})
    assert r.status_code == 200

    history = captured["history"]
    assert history is not None
    # Two prior turns → 4 messages (user+assistant pairs).
    assert len(history) == 4
    assert history[0] == {"role": "user", "content": "primera pregunta"}
    assert history[1] == {"role": "assistant", "content": "primera respuesta"}
    assert history[-1] == {"role": "assistant", "content": "segunda respuesta"}


def test_chat_ask_then_history_roundtrip(client, monkeypatch):
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "respuesta")
    monkeypatch.setattr(brain, "ask_with_tools", lambda prompt, **kw: "respuesta")

    r = client.post("/api/chat/ask", json={"text": "pregunta"})
    assert r.status_code == 200

    r = client.get("/api/chat/history?limit=50")
    assert r.status_code == 200
    history = r.json()
    assert len(history) == 1
    assert history[0]["user_text"] == "pregunta"
    assert history[0]["axi_text"] == "respuesta"


def test_chat_kill_switch_returns_503(client, monkeypatch):
    from axi import config
    monkeypatch.setattr(config, "get", lambda key, default=None: False if key == "chat_enabled" else default)
    r = client.post("/api/chat/ask", json={"text": "hola"})
    assert r.status_code == 503


def test_chat_ask_rejects_empty(client, monkeypatch):
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "no debería llamarse")
    r = client.post("/api/chat/ask", json={"text": "   "})
    assert r.status_code == 400


def test_chat_ask_records_brain_metric(client, monkeypatch):
    """The brain call from chat must also feed the brain-metrics table.

    Stubs both _ask_impl (for brain.ask) and _ask_with_tools_impl (for
    brain.ask_with_tools) since the routing now uses ask_with_tools for
    non-image turns. Either path must record the metric.
    """
    from axi import brain, store
    monkeypatch.setattr(brain, "_BG_WORKERS_DISABLED", False)  # test requires metric threads
    _stub_meta = {"model": "stub", "usage": {"total_tokens": 5, "prompt_tokens": 2, "completion_tokens": 3}}
    monkeypatch.setattr(brain, "_ask_impl", lambda prompt, **kw: ("ok", _stub_meta))
    monkeypatch.setattr(brain, "_ask_with_tools_impl", lambda prompt, **kw: ("ok", _stub_meta))

    r = client.post("/api/chat/ask", json={"text": "ping"})
    assert r.status_code == 200

    # The metric write is async — wait briefly for the daemon thread.
    import threading, time
    deadline = time.time() + 2.0
    while time.time() < deadline:
        if any(t.name == "axi-brain-metric" and t.is_alive() for t in threading.enumerate()):
            time.sleep(0.02)
            continue
        break
    metrics = store.recent_brain_metrics(limit=10)
    assert any(m.get("model") == "stub" for m in metrics)


def test_chat_history_empty(client):
    r = client.get("/api/chat/history")
    assert r.status_code == 200
    assert r.json() == []


def test_chat_history_limit_bounds(client):
    r = client.get("/api/chat/history?limit=0")
    assert r.status_code == 400
    r = client.get("/api/chat/history?limit=501")
    assert r.status_code == 400


def test_chat_page_renders(client):
    r = client.get("/chat")
    assert r.status_code == 200
    assert "Chat con Axi" in r.text


# ─── Issue 6: nano path must persist original text, not normalized text ────


def test_nano_try_extract_uses_original_text_for_body(monkeypatch):
    """_try_nano_extract must use original_text for body= fields, not the
    normalized parse_text.  We test the function directly to avoid having
    to work around the regex fast-path that catches many health phrases first.
    """
    from axi import dashboard
    from lifeos.health import entries as _he

    original = "gasté doscientos pesos en algo"
    normalized = "gasté 200 pesos en algo"

    captured_body: list[str] = []
    real_create = _he.create

    def spy_create(**kwargs):
        captured_body.append(kwargs.get("body", ""))
        return real_create(**kwargs)

    import lifeos.health.entries as _he_mod
    monkeypatch.setattr(_he_mod, "create", spy_create)

    from lifeos.agents import extractor as nano_extractor

    class _FakeHealthResult:
        domain = "health"
        kind = "note"
        title = "nota"
        systolic = None
        diastolic = None
        pulse_bpm = None
        sleep_hours = None
        weight_kg = None
        glucose_mg_dl = None
        confidence = 0.7

    monkeypatch.setattr(nano_extractor, "extract", lambda text, **kw: _FakeHealthResult())

    result = dashboard._try_nano_extract(
        normalized,
        location_tag=None,
        original_text=original,
    )
    assert result is not None
    assert result["domain"] == "health"
    # The persisted body must be the original text, not the normalized form.
    assert len(captured_body) >= 1
    assert captured_body[0] == original
    assert "doscientos" in captured_body[0]


# ─── Issue 7: nano few-shot — onset-only sleep yields null sleep_hours ─────


def test_nano_sleep_onset_only_falls_to_note(monkeypatch):
    """When nano returns kind=note and sleep_hours=null (onset-only message),
    _try_nano_extract must persist a note entry, NOT an empty vital.
    """
    from axi import dashboard
    from lifeos.agents import extractor as nano_extractor
    from lifeos.health import entries as _he

    captured_kind: list[str] = []
    real_create = _he.create

    def spy_create(**kwargs):
        captured_kind.append(kwargs.get("kind", ""))
        return real_create(**kwargs)

    import lifeos.health.entries as _he_mod
    monkeypatch.setattr(_he_mod, "create", spy_create)

    class _FakeOnsetResult:
        domain = "health"
        kind = "note"
        title = "registro de sueño"
        systolic = None
        diastolic = None
        pulse_bpm = None
        sleep_hours = None
        weight_kg = None
        glucose_mg_dl = None
        confidence = 0.7

    monkeypatch.setattr(nano_extractor, "extract", lambda text, **kw: _FakeOnsetResult())

    result = dashboard._try_nano_extract(
        "Me dormí a las 11 pm y acabo de despertar",
        location_tag=None,
    )
    assert result is not None
    assert result["domain"] == "health"
    # Must persist as note (not vital) since sleep_hours is null and kind is note.
    assert len(captured_kind) >= 1
    assert captured_kind[0] == "note"
