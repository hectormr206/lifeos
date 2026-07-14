"""Tests for the organ registry (axi.organs) + Axi self-awareness.

Covers: registry shape, reader failure isolation, service/config-backed
states, lungs vitals thresholds, body_summary, the /api/organs endpoint,
and the chat self-state context injection.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

EXPECTED_KEYS = {
    "heart", "lungs", "smell", "ears", "eyes",
    "mouth", "hands", "brain", "memory", "mind",
}
ALLOWED_STATES = {"ok", "degraded", "down", "off", "unknown"}


def _healthy_body() -> dict:
    return {
        "vram": {"name": "test", "used_mb": 1000, "total_mb": 10000,
                 "util_pct": 5, "temp_c": 45},
        "cpu_pct": 3.0,
        "cpu_temp_c": 50,
        "ram": {"used": 100, "total": 1000, "pct": 10.0, "temp_c": None},
        "disk_free_gb": 120.0,
        "on_battery": False,
    }


@pytest.fixture
def calm(monkeypatch):
    """Baseline: every service active, healthy vitals, daemon reachable."""
    from axi import organs
    monkeypatch.setattr(organs, "_service_active", lambda unit: True)
    monkeypatch.setattr(organs, "_daemon_cmd", lambda *a, **k: "active")
    monkeypatch.setattr(organs, "_body_snapshot", lambda: _healthy_body())
    return organs


# ─────────────────────────── registry shape ──────────────────────────────

def test_all_organs_returns_expected_keys(calm):
    entries = calm.all_organs()
    assert {e["key"] for e in entries} == EXPECTED_KEYS


def test_every_entry_has_valid_state_and_detail(calm):
    for e in calm.all_organs():
        assert e["state"] in ALLOWED_STATES, e
        assert isinstance(e["detail"], str)
        assert isinstance(e["name"], str) and e["name"]


def test_raising_reader_yields_unknown_and_never_raises(calm, monkeypatch):
    organ = next(o for o in calm._ORGANS if o["key"] == "heart")

    def boom(ctx):
        raise RuntimeError("sensor exploded")

    monkeypatch.setitem(organ, "reader", boom)
    entries = calm.all_organs()  # must not raise
    heart = next(e for e in entries if e["key"] == "heart")
    assert heart["state"] == "unknown"


# ─────────────────────── service-backed organs ───────────────────────────

def test_service_backed_organ_active_is_ok(calm):
    heart = next(e for e in calm.all_organs() if e["key"] == "heart")
    assert heart["state"] == "ok"


def test_service_backed_organ_inactive_is_down(calm, monkeypatch):
    monkeypatch.setattr(calm, "_service_active", lambda unit: False)
    entries = calm.all_organs()
    heart = next(e for e in entries if e["key"] == "heart")
    hands = next(e for e in entries if e["key"] == "hands")
    assert heart["state"] == "down"
    assert hands["state"] == "down"


# ─────────────────────── config-backed organs ────────────────────────────

def test_mind_off_when_autonomous_disabled(calm, monkeypatch):
    from axi import config
    real_get = config.get

    def fake_get(key, default=None):
        if key == "autonomous_enabled":
            return False
        return real_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)
    mind = next(e for e in calm.all_organs() if e["key"] == "mind")
    assert mind["state"] == "off"


def test_mouth_off_when_tts_disabled(calm, monkeypatch):
    from axi import config
    real_get = config.get

    def fake_get(key, default=None):
        if key == "tts_enabled":
            return False
        return real_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)
    mouth = next(e for e in calm.all_organs() if e["key"] == "mouth")
    assert mouth["state"] == "off"


# ─────────────────────────── lungs (vitals) ──────────────────────────────

def test_lungs_ok_with_healthy_vitals(calm):
    lungs = next(e for e in calm.all_organs() if e["key"] == "lungs")
    assert lungs["state"] == "ok"


def test_lungs_degraded_near_threshold(calm, monkeypatch):
    body = _healthy_body()
    body["vram"]["used_mb"] = 9600  # 96% of 10000 → near VRAM_FULL_PCT
    monkeypatch.setattr(calm, "_body_snapshot", lambda: body)
    lungs = next(e for e in calm.all_organs() if e["key"] == "lungs")
    assert lungs["state"] == "degraded"


def test_lungs_degraded_on_low_disk(calm, monkeypatch):
    body = _healthy_body()
    body["disk_free_gb"] = 1.5  # below disk_min_gb_free default (2)
    monkeypatch.setattr(calm, "_body_snapshot", lambda: body)
    lungs = next(e for e in calm.all_organs() if e["key"] == "lungs")
    assert lungs["state"] == "degraded"


def test_body_snapshot_called_once_per_pass(calm, monkeypatch):
    calls = {"n": 0}

    def counting():
        calls["n"] += 1
        return _healthy_body()

    monkeypatch.setattr(calm, "_body_snapshot", counting)
    calm.all_organs()
    assert calls["n"] == 1  # shared across lungs + brain readers


# ─────────────────────────── body_summary ────────────────────────────────

def test_body_summary_non_empty_and_compact(calm):
    s = calm.body_summary()
    assert isinstance(s, str) and s.strip()
    assert len(s.splitlines()) <= 3


def test_body_summary_mentions_bad_organ(calm, monkeypatch):
    monkeypatch.setattr(calm, "_service_active",
                        lambda unit: unit != "axi-heartbeat.service")
    s = calm.body_summary()
    assert "coraz" in s.lower()  # corazón mentioned when down


# ─────────────────────────── /api/organs ─────────────────────────────────

@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def test_api_organs_endpoint(client, calm):
    r = client.get("/api/organs")
    assert r.status_code == 200
    data = r.json()
    assert "organs" in data
    assert {e["key"] for e in data["organs"]} == EXPECTED_KEYS
    for e in data["organs"]:
        assert e["state"] in ALLOWED_STATES


# ──────────────────── chat self-state detection ──────────────────────────

SELF_STATE_POSITIVE = [
    "¿cómo estás?",
    "como estas",
    "Axi, ¿cómo te sientes?",
    "cómo va tu cuerpo",
    "cómo va tu sistema",
    "cómo andas",
    "how are you",
    "how are you doing",
    "how are you feeling",
    "how do you feel",
    "status report",
    "dame el estado de tu cuerpo",
]

SELF_STATE_NEGATIVE = [
    "cómo está mi mamá",
    "how are the finances",
    "cómo va tu día laboral según mi agenda",  # no cuerpo/sistema
    "cuánto gasté ayer",
    "recuérdame comprar café",
]


@pytest.mark.parametrize("text", SELF_STATE_POSITIVE)
def test_self_state_regex_matches(text):
    from axi import organs
    assert organs.is_self_state_question(text), text


@pytest.mark.parametrize("text", SELF_STATE_NEGATIVE)
def test_self_state_regex_rejects(text):
    from axi import organs
    assert not organs.is_self_state_question(text), text


# ──────────────────── chat context injection ─────────────────────────────

def _capture_brain(monkeypatch):
    """Capture the `system` of EVERY brain call (the background fact
    extractor also calls brain.ask, so a single-slot capture races)."""
    from axi import brain
    captured: list[str] = []

    def fake(prompt, **kw):
        captured.append(kw.get("system") or "")
        return "respuesta"

    monkeypatch.setattr(brain, "ask", fake)
    monkeypatch.setattr(brain, "ask_with_tools", fake)
    return captured


def _quiet_router(monkeypatch):
    from axi import chat_router
    monkeypatch.setattr(chat_router, "route_and_handle", lambda *a, **k: None)


def test_chat_self_state_injects_body_summary(client, calm, monkeypatch):
    captured = _capture_brain(monkeypatch)
    _quiet_router(monkeypatch)
    monkeypatch.setattr(calm, "body_summary", lambda lang=None: "CUERPO-TEST-RESUMEN")

    r = client.post("/api/chat/ask", json={"text": "¿cómo estás?"})
    assert r.status_code == 200
    assert any("CUERPO-TEST-RESUMEN" in s for s in captured)


def test_chat_normal_message_does_not_inject(client, calm, monkeypatch):
    captured = _capture_brain(monkeypatch)
    _quiet_router(monkeypatch)
    monkeypatch.setattr(calm, "body_summary", lambda lang=None: "CUERPO-TEST-RESUMEN")

    r = client.post("/api/chat/ask", json={"text": "cuéntame un chiste"})
    assert r.status_code == 200
    assert not any("CUERPO-TEST-RESUMEN" in s for s in captured)


def test_chat_self_state_organs_error_never_breaks_chat(client, monkeypatch):
    from axi import organs
    captured = _capture_brain(monkeypatch)
    _quiet_router(monkeypatch)

    def boom(lang=None):
        raise RuntimeError("body offline")

    monkeypatch.setattr(organs, "body_summary", boom)
    r = client.post("/api/chat/ask", json={"text": "¿cómo estás?"})
    assert r.status_code == 200
    assert r.json()["answer"] == "respuesta"
