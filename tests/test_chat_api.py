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
    """The brain.ask call from chat must also feed the brain-metrics table.

    We don't mock _record_metric_async directly — we exercise the real
    `brain.ask` wrapper with a stub `_ask_impl`, then check the store.
    """
    from axi import brain, store
    monkeypatch.setattr(brain, "_ask_impl", lambda prompt, **kw: ("ok", {"model": "stub", "usage": {"total_tokens": 5, "prompt_tokens": 2, "completion_tokens": 3}}))

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
