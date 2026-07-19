"""Chat confirmation names the family subject + the full parsed reading.

When a family subject is detected ("Mi esposa tuvo 121, 79, 61 pulsos"), the
health register confirmation must name the person AND report the full reading,
e.g. "Anotado para tu esposa: presión 121/79, pulso 61" — not a bare, under-
reported "pulso 96". For the user's own readings the self phrasing is kept.
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock


# ── unit: possessive phrasing helper ────────────────────────────────────────

def test_subject_possessive_es() -> None:
    from lifeos._common.subject import subject_possessive
    assert subject_possessive("esposa") == "tu esposa"
    assert subject_possessive("mamá") == "tu mamá"
    assert subject_possessive("papá") == "tu papá"


def test_subject_possessive_en() -> None:
    from lifeos._common.subject import subject_possessive
    assert subject_possessive("esposa", en=True) == "your wife"
    assert subject_possessive("papá", en=True) == "your dad"


# ── integration: dashboard health fast-path confirmation ────────────────────

def _make_chat_client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10})
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0})
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)
    from fastapi.testclient import TestClient
    return TestClient(dashboard.app)


def test_family_confirmation_names_subject_and_full_reading(monkeypatch) -> None:
    from axi import dashboard
    client = _make_chat_client(monkeypatch)
    mock_entry = SimpleNamespace(id="h-conf-1", kind="vital")
    monkeypatch.setattr(dashboard.health_entries, "create",
                        MagicMock(return_value=mock_entry))

    r = client.post("/api/chat/ask", json={
        "text": "Mi esposa tuvo 121, 79, 61 pulsos", "logging_mode": False})

    assert r.status_code == 200
    answer = r.json()["answer"]
    assert "tu esposa" in answer, answer
    assert "121/79" in answer and "56" in answer, answer


def test_self_confirmation_keeps_self_phrasing(monkeypatch) -> None:
    from axi import dashboard
    client = _make_chat_client(monkeypatch)
    mock_entry = SimpleNamespace(id="h-conf-2", kind="vital")
    monkeypatch.setattr(dashboard.health_entries, "create",
                        MagicMock(return_value=mock_entry))

    r = client.post("/api/chat/ask", json={
        "text": "presión 120/80", "logging_mode": False})

    assert r.status_code == 200
    answer = r.json()["answer"]
    assert "tu esposa" not in answer and "para tu" not in answer, answer
    assert "120/80" in answer, answer
