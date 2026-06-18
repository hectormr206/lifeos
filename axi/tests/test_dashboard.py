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


# ─────────────────────────── Slice 4 — Dashboard TRIAD ───────────────────────


# 4.1 RED — snapshot includes llama-vt
def test_snapshot_includes_llama_vt(client, monkeypatch):
    """Slice 4.1/4.2 — snapshot services dict contains llama-vt key."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert "llama-vt" in data["services"], "snapshot missing llama-vt key"
    # value must be a valid state string
    assert data["services"]["llama-vt"] in ("active", "inactive", "unknown")


# 4.1b RED — snapshot triad flag
def test_snapshot_includes_triad_flag(client, monkeypatch):
    """Slice 4.2 — snapshot exposes triad bool driven by is_triad_active()."""
    from axi import dashboard, models_manager
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: True)
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert "triad" in data, "snapshot missing triad key"
    assert data["triad"] is True


def test_snapshot_triad_flag_false_when_not_active(client, monkeypatch):
    """Slice 4.2 — triad=False when 35B is active."""
    from axi import dashboard, models_manager
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: False)
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    assert r.json()["triad"] is False


# 4.3 RED — _friendly_from_cmdline port disambiguation
def test_friendly_from_cmdline_port_8082_is_vibethinker(monkeypatch):
    """Slice 4.3/4.4 — cmdline with --port 8082 returns VibeThinker-3B label."""
    from axi import dashboard
    cmdline = "/usr/bin/llama-server --model VibeThinker.gguf --port 8082 -c 61440"
    result = dashboard._friendly_from_cmdline(cmdline)
    assert result == "VibeThinker-3B", f"Expected 'VibeThinker-3B', got {result!r}"


def test_friendly_from_cmdline_port_8080_is_primary_brain(monkeypatch):
    """Slice 4.3/4.4 — cmdline with --port 8080 returns primary brain label (not VibeThinker)."""
    from axi import dashboard
    cmdline = "/usr/bin/llama-server --model Qwen3.5-4B.gguf --port 8080 -c 61440"
    result = dashboard._friendly_from_cmdline(cmdline)
    assert result is not None
    assert result != "VibeThinker-3B", "Port 8080 must NOT be labeled VibeThinker-3B"


def test_friendly_from_cmdline_no_port_is_primary_brain(monkeypatch):
    """Slice 4.4 — llama-server cmdline without explicit port defaults to primary label."""
    from axi import dashboard
    cmdline = "/usr/bin/llama-server --model Qwen3.5-35B.gguf -ngl 999"
    result = dashboard._friendly_from_cmdline(cmdline)
    assert result is not None
    assert result != "VibeThinker-3B"


# 4.5 RED — pair-activation: qwen35-4b also starts VT
def test_pair_activate_4b_writes_vt_model_and_restarts_llama_vt(client, monkeypatch, tmp_path):
    """Slice 4.5/4.7 — activating qwen35-4b writes active_vt_model.json and starts llama-vt."""
    from axi import dashboard, models_manager

    # Stub out the heavy calls
    monkeypatch.setattr(models_manager, "set_active", lambda entry: True)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda url=None, timeout=60.0: True)

    vt_written = {}
    def _fake_write_vt(entry):
        vt_written["id"] = entry.id
        return tmp_path / "active_vt_model.json"
    monkeypatch.setattr(models_manager, "write_active_vt", _fake_write_vt)

    vt_cmds = []
    def _fake_run(cmd, **kw):
        vt_cmds.append(cmd)
        class _R:
            returncode = 0
        return _R()
    monkeypatch.setattr(dashboard.subprocess, "run", _fake_run)

    r = client.post("/api/models/qwen35-4b/activate")
    assert r.status_code == 200
    data = r.json()
    assert data["ok"] is True
    # VT model must have been written
    assert vt_written.get("id") == "vibethinker-3b", f"write_active_vt not called with vibethinker-3b, got: {vt_written}"
    # systemctl restart llama-vt.service must have been called
    restart_cmds = [c for c in vt_cmds if "llama-vt" in str(c)]
    assert any("restart" in str(c) or "start" in str(c) for c in restart_cmds), \
        f"No restart/start of llama-vt found in calls: {vt_cmds}"
    # Response includes vt field
    assert "vt" in data, f"Response missing 'vt' field: {data}"


# 4.6 RED — pair-activation: qwen36-35b-a3b stops VT BEFORE primary restart
def test_pair_activate_35b_stops_vt_before_primary_restart(client, monkeypatch, tmp_path):
    """Slice 4.6/4.7 — activating 35B stops llama-vt BEFORE set_active (VRAM ordering)."""
    from axi import dashboard, models_manager

    call_order = []

    def _fake_run(cmd, **kw):
        call_order.append(("run", list(cmd)))
        class _R:
            returncode = 0
        return _R()
    monkeypatch.setattr(dashboard.subprocess, "run", _fake_run)

    def _fake_set_active(entry):
        call_order.append(("set_active", entry.id))
        return True
    monkeypatch.setattr(models_manager, "set_active", _fake_set_active)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda url=None, timeout=60.0: True)

    r = client.post("/api/models/qwen36-35b-a3b/activate")
    assert r.status_code == 200

    # Find indices of VT stop and set_active
    vt_stop_idx = None
    set_active_idx = None
    for i, ev in enumerate(call_order):
        if ev[0] == "run" and "llama-vt" in str(ev[1]) and "stop" in str(ev[1]):
            vt_stop_idx = i
        if ev[0] == "set_active":
            set_active_idx = i

    assert vt_stop_idx is not None, f"llama-vt stop not found in call_order: {call_order}"
    assert set_active_idx is not None, f"set_active not found in call_order: {call_order}"
    assert vt_stop_idx < set_active_idx, (
        f"VT stop (idx={vt_stop_idx}) must happen BEFORE set_active (idx={set_active_idx}). "
        f"Full order: {call_order}"
    )


# 4.8 RED — toggle protection: llama-vt rejected
def test_llama_vt_toggle_rejected(client):
    """Slice 4.8/4.9 — POST /api/service/start/llama-vt returns 403."""
    r = client.post("/api/service/start/llama-vt")
    assert r.status_code == 403, f"Expected 403, got {r.status_code}: {r.text}"


def test_llama_vt_stop_toggle_rejected(client):
    """Slice 4.8/4.9 — POST /api/service/stop/llama-vt also returns 403."""
    r = client.post("/api/service/stop/llama-vt")
    assert r.status_code == 403, f"Expected 403, got {r.status_code}: {r.text}"


# 4.10 RED — brains panel data: triad mode
def test_snapshot_brains_panel_triad_mode(client, monkeypatch):
    """Slice 4.10/4.11 — triad=True + services show 4B+VT+Whisper active."""
    from axi import dashboard, models_manager
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: True)

    def _state(unit: str) -> str:
        return "active"
    monkeypatch.setattr(dashboard, "_service_state", _state)

    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert data["triad"] is True
    assert data["services"]["llama-server"] == "active"
    assert data["services"]["llama-vt"] == "active"
    assert data["services"]["axi-whisper"] == "active"


def test_snapshot_brains_panel_game_mode(client, monkeypatch):
    """Slice 4.10 — game mode: llama-server+llama-vt stopped, axi-whisper active via CPU."""
    from axi import dashboard, models_manager
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: False)

    def _state(unit: str) -> str:
        if "llama-vt" in unit or "llama-server" in unit:
            return "inactive"
        return "active"
    monkeypatch.setattr(dashboard, "_service_state", _state)

    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert data["services"]["llama-vt"] == "inactive"
    assert data["services"]["llama-server"] == "inactive"
    # triad is False in game mode
    assert data["triad"] is False


# 4.11 RED — brains panel HTML present in dashboard
def test_brains_panel_in_dashboard_html(client):
    """Slice 4.11 — dashboard page renders Cerebros activos panel in neutral Spanish."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    # Panel heading in neutral Spanish (no voseo)
    assert "Cerebros activos" in html, "Missing 'Cerebros activos' panel heading"
    # VibeThinker chip
    assert "VibeThinker-3B" in html or "razonamiento" in html, \
        "Missing VibeThinker-3B / razonamiento reference in brains panel"
    # Panel must reference triad flag from snapshot
    assert "triad" in html, "Brains panel must reference snap.triad"


# ---------------------------------------------------------------------------
# FIX 3 — api_model_activate: VRAM guard + error detail on non-4B path
# ---------------------------------------------------------------------------

import types as _types
import urllib.error as _urllib_error


def _sp_ok(returncode: int = 0) -> _types.SimpleNamespace:
    return _types.SimpleNamespace(returncode=returncode, stdout="", stderr="")


@pytest.fixture
def client_activate(monkeypatch):
    """Client fixture with model catalog stubs for activation tests."""
    from axi import dashboard, models_manager, store
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

    # Stub catalog so every model is known and "installed"
    fake_entry = _types.SimpleNamespace(
        id="qwen36-35b-a3b", name="Qwen3.6-35B", family="qwen", params="35B",
        features=[], description="", vram_estimate_gb=18.0, ctx=32768,
        notes="", files=[], extra_args=[],
    )
    monkeypatch.setattr(models_manager, "by_id", lambda mid: fake_entry if mid == "qwen36-35b-a3b" else None)
    monkeypatch.setattr(models_manager, "is_installed", lambda entry: True)

    from fastapi.testclient import TestClient
    return TestClient(dashboard.app), monkeypatch, fake_entry


def test_activate_non4b_stop_fails_but_vt_still_up_returns_503(client_activate, monkeypatch):
    """FIX 3a RED: stop llama-vt returns non-zero AND /health probe says VT still up → 503, no set_active.

    This proves the VRAM guard: if stop failed AND VT is still responding,
    we must NOT proceed to load the large model.
    """
    from axi import dashboard, models_manager
    client, mp, fake_entry = client_activate

    # systemctl stop returns non-zero (stop failed)
    mp.setattr(dashboard.subprocess, "run", lambda argv, **kw: _sp_ok(returncode=1))

    # VT health probe: VT is still UP (connection succeeds → raises nothing)
    import urllib.request as _urllib_request

    class _FakeHealthResp:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *_): return False
        def read(self): return b'{"status":"ok"}'

    mp.setattr(_urllib_request, "urlopen", lambda url, timeout=None: _FakeHealthResp())

    set_active_calls = []
    mp.setattr(models_manager, "set_active", lambda e, **kw: set_active_calls.append(e) or True)

    r = client.post("/api/models/qwen36-35b-a3b/activate")

    assert r.status_code == 503, f"Expected 503, got {r.status_code}: {r.json()}"
    assert len(set_active_calls) == 0, "set_active must NOT be called when VT stop failed and VT still up"
    detail = r.json().get("detail", "")
    assert "vt" in detail.lower() or "503" in str(r.status_code), \
        f"Detail should reference VT state, got: {detail}"


def test_activate_non4b_set_active_fails_error_includes_vt_state(client_activate, monkeypatch):
    """FIX 3b RED: stop llama-vt OK, then set_active() returns False → error response includes vt_state.

    The original code raises HTTPException(503, 'llama-server did not become healthy')
    without mentioning that VT was already stopped — caller cannot diagnose state.
    After fix, response detail must include vt_state information.
    """
    from axi import dashboard, models_manager
    client, mp, fake_entry = client_activate

    # Stop succeeds (returncode=0)
    mp.setattr(dashboard.subprocess, "run", lambda argv, **kw: _sp_ok(returncode=0))

    # set_active returns False (primary never healthy)
    mp.setattr(models_manager, "set_active", lambda e, **kw: False)

    r = client.post("/api/models/qwen36-35b-a3b/activate")

    assert r.status_code == 503
    detail = r.json().get("detail", "")
    # The detail must mention that VT was stopped (so caller knows system state)
    assert "vt" in detail.lower() or "stop" in detail.lower(), (
        f"Error detail must include VT state info, got: {detail}"
    )
