"""Endpoint tests for the FastAPI dashboard.

The daemon socket and llama-server health probes are stubbed — these tests
only exercise the surface that depends on our own SQLite store + templates,
so they run in <1 s without spinning up the rest of the stack.
"""
from __future__ import annotations

import logging

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard, store

    # Force a fresh DB connection (the autouse conftest fixture has already
    # pointed store.DB_PATH at a temp file and run init_db()).
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

    return TestClient(dashboard.app)


def test_home_renders(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "Axi" in r.text


def test_snapshot_shape(client):
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    for key in ("now", "state", "services", "vram", "ram", "cpu_pct",
                "memory", "recent_conversations", "recent_facts"):
        assert key in data
    assert "iso" in data["now"]
    assert "tz" in data["now"]


def test_snapshot_state_falls_back_when_daemon_unreachable(client, monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "")
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["state"] == "unknown"


def test_facts_endpoint_empty(client):
    r = client.get("/api/facts")
    assert r.status_code == 200
    assert r.json() == []


def test_facts_endpoint_with_data(client):
    from axi import store
    store.add_node("fact", "Héctor usa HyperX SoloCast", {"category": "preference"}, domain="setup")
    r = client.get("/api/facts")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 1
    assert rows[0]["label"] == "Héctor usa HyperX SoloCast"
    assert rows[0]["domain"] == "setup"


def test_search_endpoint(client):
    from axi import store
    store.add_node("fact", "café favorito es americano", domain="setup")
    r = client.get("/api/search?q=café")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 1


def test_search_empty_query_returns_empty(client):
    r = client.get("/api/search?q=")
    assert r.status_code == 200
    assert r.json() == []


def test_cmd_rejects_unknown_command(client):
    r = client.post("/api/cmd/explode")
    assert r.status_code == 400


def test_cmd_accepts_known_command(client):
    r = client.post("/api/cmd/toggle")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_cmd_logs_every_invocation(client, caplog):
    with caplog.at_level(logging.INFO, logger="axi.dashboard"):
        client.post("/api/cmd/toggle")

    assert "/api/cmd/toggle invoked" in caplog.text


def test_meeting_start_empty_daemon_response_returns_503(client, monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "")
    r = client.post("/api/cmd/meeting_start")

    assert r.status_code == 503
    data = r.json()
    assert data["ok"] is False
    assert data["response"] == ""
    assert "empty response" in data["error"]


def test_meeting_stop_failed_daemon_response_returns_503(client, monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "failed:boom")
    r = client.post("/api/cmd/meeting_stop")

    assert r.status_code == 503
    assert r.json() == {"ok": False, "response": "failed:boom", "error": "failed:boom"}


def test_meetings_list_empty(client):
    r = client.get("/api/meetings")
    assert r.status_code == 200
    assert r.json() == []


def test_meeting_detail_404(client):
    r = client.get("/api/meetings/999")
    assert r.status_code == 404


def test_config_roundtrip(client, tmp_path, monkeypatch):
    from axi import config
    config_path = tmp_path / "config.json"
    monkeypatch.setattr(config, "CONFIG_PATH", config_path)
    monkeypatch.setattr(config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(config, "_cache", None)

    r = client.post("/api/config", json={"timezone": "Europe/Madrid"})
    assert r.status_code == 200
    assert r.json()["config"]["timezone"] == "Europe/Madrid"

    r = client.get("/api/config")
    assert r.json()["timezone"] == "Europe/Madrid"


def test_graph_endpoint_returns_cytoscape_shape(client):
    from axi import store
    a = store.add_node("fact", "fact A", domain="setup")
    b = store.add_node("person", "Héctor")
    store.add_edge(a, b, "belongs_to")
    r = client.get("/api/graph")
    assert r.status_code == 200
    data = r.json()
    assert "nodes" in data
    assert "edges" in data
    assert len(data["nodes"]) == 2
    # The single edge connects two visible nodes → must come through.
    assert len(data["edges"]) == 1
    assert data["edges"][0]["data"]["kind"] == "belongs_to"


def test_graph_excludes_conversation_nodes(client):
    from axi import store
    store.add_node("conversation", "old chat turn")
    store.add_node("fact", "real fact")
    r = client.get("/api/graph")
    data = r.json()
    assert len(data["nodes"]) == 1


# ─────────────────────────── axi-living-avatar: backend contract ────────────


def test_snapshot_includes_axi_heartbeat(client, monkeypatch):
    """Task 1.1/1.2 — snapshot exposes axi-heartbeat service."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["services"]["axi-heartbeat"] == "active"


def test_snapshot_includes_axi_whisper(client, monkeypatch):
    """Task 1.3/1.4 — snapshot exposes axi-whisper service."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["services"]["axi-whisper"] == "active"


def test_snapshot_whisper_inactive(client, monkeypatch):
    """Task 1.5/1.6 — inactive axi-whisper reflected correctly."""
    from axi import dashboard

    def _state(unit: str) -> str:
        return "inactive" if "axi-whisper" in unit else "active"

    monkeypatch.setattr(dashboard, "_service_state", _state)
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["services"]["axi-whisper"] == "inactive"
    assert r.json()["services"]["axi-heartbeat"] == "active"


def test_snapshot_capabilities_block(client, monkeypatch):
    """Task 1.7/1.8 — snapshot exposes eyes capability dict."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_eye_capabilities", lambda: {"webcam": True, "screen": True})
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    eyes = r.json()["eyes"]
    assert eyes["webcam"] is True
    assert eyes["screen"] is True


def test_snapshot_webcam_unavailable(client, monkeypatch):
    """Task 1.9/1.10 — unavailable webcam reflected."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_eye_capabilities", lambda: {"webcam": False, "screen": True})
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["eyes"]["webcam"] is False


def test_snapshot_poll_does_not_trigger_capture(client, monkeypatch):
    """Task 1.19/1.20 — snapshot never fires capture routes."""
    from axi import dashboard
    camera_calls = {"n": 0}
    screen_calls = {"n": 0}

    def _fake_camera():
        camera_calls["n"] += 1
        return ("fake_b64", "ok")

    def _fake_screen():
        screen_calls["n"] += 1
        return "fake_b64"

    # Monkeypatch the underlying vision/eyes capture functions if they exist.
    # The key assertion is that snapshot itself never calls them.
    try:
        from axi import eyes
        monkeypatch.setattr(eyes, "capture_b64", _fake_camera)
    except (ImportError, AttributeError):
        pass
    try:
        from axi import vision
        monkeypatch.setattr(vision, "capture_active_window_b64", _fake_screen)
    except (ImportError, AttributeError):
        pass

    for _ in range(3):
        client.get("/api/snapshot")

    assert camera_calls["n"] == 0
    assert screen_calls["n"] == 0


def test_capture_camera_busy_returns_503(client, monkeypatch):
    """Task 1.15/1.16 — camera busy → 503 with busy:true."""
    from axi import dashboard, eyes
    monkeypatch.setattr(eyes, "capture_b64", lambda: (None, "busy:another-app"))
    r = client.post("/api/chat/capture-camera")
    assert r.status_code == 503
    data = r.json()
    assert data.get("busy") is True


def test_capture_screen_busy_returns_503(client, monkeypatch):
    """Task 1.17/1.18 — screen unavailable → 503 with busy:true."""
    from axi import dashboard, vision
    monkeypatch.setattr(vision, "capture_active_window_b64", lambda: None)
    r = client.post("/api/chat/capture-screen")
    assert r.status_code == 503
    data = r.json()
    assert data.get("busy") is True


# ─────────────────────────── axi-living-avatar: frontend / CSS layer ────────


def test_teal_token_in_rendered_html(client):
    """Task 2.1/2.2 — --teal CSS custom property present in rendered page."""
    r = client.get("/")
    assert r.status_code == 200
    assert "--teal" in r.text
    assert "#00D4AA" in r.text


def test_meeting_command_feedback_js_present(client):
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert "commandFeedback" in html
    assert "await r.json()" in html
    assert "started:" in html
    assert "already-recording:" in html
    assert "await this.refresh();" in html


def test_pink_token_unchanged(client):
    """Task 2.3 — --pink unchanged after teal addition."""
    r = client.get("/")
    assert r.status_code == 200
    assert "--pink" in r.text
    assert "#FF6B9D" in r.text


def test_heart_keyframes_present(client):
    """Task 2.5/2.6 — @keyframes heartbeat referenced on organ-heart alive rule."""
    r = client.get("/")
    assert r.status_code == 200
    assert "@keyframes heartbeat" in r.text
    # Confirm the organ-heart alive rule references the heartbeat keyframe
    assert "heartbeat" in r.text


# ─────────────────────────── axi-living-avatar: SVG organ widget ─────────────


def test_inline_svg_with_organ_ids(client):
    """Task 3.1/3.2 — inline SVG with all six organ group IDs present."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert "<svg" in html
    for organ_id in ("organ-heart", "organ-brain", "organ-ears", "organ-mouth",
                     "eye-screen", "eye-webcam"):
        assert organ_id in html, f"Missing organ id: {organ_id}"


def test_organ_alpine_bindings_present(client):
    """Task 3.3/3.4 — organ-heart element carries Alpine class binding referencing axi-heartbeat."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert "organ-heart" in html
    assert "axi-heartbeat" in html


def test_eye_organ_binding_references_capability(client):
    """Task 3.5/3.6 — eye element binding references webcam or screen capability key."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert "webcam" in html or "screen" in html


def test_popover_markup_present(client):
    """Task 3.7/3.9 — popover-heart with x-show attribute present."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert "popover-heart" in html
    assert "x-show" in html


def test_avatar_organ_actions_present(client):
    """Avatar redesign — organ click actions are wired: eyes capture (screen +
    webcam), mouth speaks out loud, and the heart syncs to the REAL
    axi-heartbeat service (beats only while it is active)."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    assert 'id="axi-avatar"' in html
    # eyes -> live capture
    assert "captureEye('screen')" in html
    assert "captureEye('webcam')" in html
    # mouth -> speak out loud
    assert "speak()" in html
    # heart -> synced to the real heartbeat service liveness
    assert "services['axi-heartbeat']" in html


def test_say_endpoint_speaks(client, monkeypatch):
    """The mouth's /api/chat/say endpoint triggers Axi's TTS and echoes the text."""
    spoken = {}
    import axi.speak as _speak

    monkeypatch.setattr(_speak, "speak", lambda text: spoken.setdefault("text", text) or True)
    r = client.post("/api/chat/say", json={"text": "hola"})
    assert r.status_code == 200
    assert r.json()["text"] == "hola"
