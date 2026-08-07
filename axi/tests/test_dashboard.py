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


def test_legacy_graph_endpoint_removed(client):
    """The legacy 2D Cytoscape /api/graph endpoint was retired in Stage 2 —
    the 3D browser uses /api/graph/full. It must now 404."""
    assert client.get("/api/graph").status_code == 404


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


def test_new_clickable_organs_present(client):
    """Every-organ-clickable — lungs (gills), smell (nostrils), feet, and the
    immune outline are clickable groups wired to the generic organ popover."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    for organ_id in ("organ-lungs", "organ-smell", "organ-feet", "organ-immune"):
        assert organ_id in html, f"Missing organ id: {organ_id}"
        assert f"openOrgan('{organ_id.split('-')[1]}')" in html
    # Generic popover fed by /api/organs at click time.
    assert "popover-organ" in html
    assert "/api/organs" in html
    assert "en desarrollo" in html


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


def test_avatar_vital_animations_present(client):
    """Vital animations — breathing/heartbeat speeds and face mood derive
    client-side from the already-polled snapshot (zero new backend polling):
    CSS custom properties parametrize the gill/heart keyframes, and the mouth
    swaps to a tired path when anything is degraded."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    # CSS custom properties with calm fallbacks parametrize the animations.
    assert "var(--breath-dur, 4s)" in html
    assert "var(--pulse-dur, 2s)" in html
    # The SVG root binds both vars from live vitals.
    assert "'--breath-dur': breathDur()" in html
    assert "'--pulse-dur': pulseDur()" in html
    # Client-side stress model + thresholds (no /api/organs polling).
    assert "vitalsStressed()" in html
    assert "stressLevel()" in html
    assert "VITAL_THRESHOLDS" in html
    # Face mood: smile + tired mouth paths toggled inside the clickable mouth.
    assert 'id="mouth-smile"' in html
    assert 'id="mouth-tired"' in html
    assert "faceTired()" in html
    # Tired eyelids are decorative only (eyes keep their capture clicks).
    assert 'id="face-tired-eyelids"' in html


def test_avatar_game_mode_vitals_bypass(client):
    """Game mode — while gaming the machine legitimately runs hot/high, so the
    avatar must not look permanently stressed (alarm fatigue). A gameMode()
    helper (same snap field #game-glow uses) makes vitalsStressed() ignore the
    load/thermal family (VRAM ratio, GPU/CPU temps) — disk-low and core-service
    -down still count — and breathing settles on a focused 2.5s rate."""
    r = client.get("/")
    assert r.status_code == 200
    html = r.text
    # Helper exists and derives from the SAME snap field #game-glow uses.
    assert "gameMode()" in html
    assert "GAME_MODE_LABEL = 'Modo juego'" in html
    assert "s.models.mode === GAME_MODE_LABEL" in html
    # Named breathing constants: calm 4s / focused 2.5s / stressed 1.4s.
    assert "BREATH_DUR_S" in html
    assert "focused: 2.5" in html
    assert "calm: 4" in html
    assert "stressed: 1.4" in html
    # Load/thermal family bypass inside vitalsStressed() during game mode.
    assert "const gaming = this.gameMode();" in html
    assert "if (!gaming)" in html
    # Non-game stress (service down / disk) keeps the stressed breathing rate
    # even during game mode; otherwise the focused rate applies.
    assert "this.stressLevel() > 0 ? BREATH_DUR_S.stressed : BREATH_DUR_S.focused" in html
    # #game-glow reuses the same helper (single source of truth).
    assert '''gameMode() ? 'game-active' : ''"''' in html


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
    # The endpoint refuses with 409 unless every file of the bundle is on disk.
    # This test is about the VT sibling being started, not about installation,
    # and the model weights only exist on a machine that downloaded them.
    monkeypatch.setattr(models_manager, "is_installed", lambda entry: True)

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
    # The endpoint refuses with 409 unless every file of the bundle is on disk.
    # This test is about VRAM ordering, not about installation, and the model
    # weights only exist on a machine that downloaded them.
    monkeypatch.setattr(models_manager, "is_installed", lambda entry: True)

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


# ─────────────────────────────────────────────────────────────────────────────
# PR6b — dashboard.py reader rewrite to src_uuid/dst_uuid/relation
#
# Tasks 6b.1-6b.3 of openspec/changes/sync-over-vpn. Four read sites move off
# the integer from_id/to_id join and off edges.kind, onto the sync-stable
# endpoint uuids and the generated `relation` column.
#
# The literal PRE-REWRITE queries are kept below as ORACLES. They still work
# (PR5 dual-writes both representations and PR8 is what finally drops the old
# columns), so they are the only honest definition of "identical results":
# each test runs the oracle against the same seeded DB the endpoint just read
# and compares. They are regression guards by design — they must stay green
# across the rewrite, which is exactly the claim being made.
# ─────────────────────────────────────────────────────────────────────────────

# PR7 note: `deleted_at IS NULL` was added to all five oracles.
#
# They are the PRE-REWRITE queries, kept to prove that resolving an edge
# through `src_uuid`/`dst_uuid` returns exactly what resolving it through
# `from_id`/`to_id` returned. That claim is about the ENDPOINT COLUMNS and it
# still holds. PR7 changes something else — a tombstoned row is invisible —
# and that change applies to the old columns just as much as to the new ones.
# Leaving the filter off would turn these into assertions that the rewrite
# preserved PR6b's tombstone behaviour, which is precisely the expectation PR7
# exists to break. Tombstone invisibility has its own tests (7.9b) below.
_ORACLE_CONV_FACT_IDS = (
    "SELECT e.to_id FROM edges e "
    "JOIN nodes n ON n.id = e.to_id "
    "WHERE e.from_id = ? AND n.kind = 'fact' "
    "AND e.deleted_at IS NULL AND n.deleted_at IS NULL"
)
_ORACLE_ALL_EDGES = (
    "SELECT e.id, e.from_id, e.to_id, e.kind FROM edges e "
    "JOIN nodes s ON s.id = e.from_id JOIN nodes d ON d.id = e.to_id "
    "WHERE e.deleted_at IS NULL "
    "AND s.deleted_at IS NULL AND d.deleted_at IS NULL"
)
_ORACLE_EDGES_TOUCHING_NODE = (
    "SELECT e.id AS eid, e.kind AS ekind, e.from_id, e.to_id, "
    "       n.id AS oid, n.kind AS okind, n.label AS olabel, n.created_at AS ocreated "
    "FROM edges e "
    "JOIN nodes n ON n.id = CASE WHEN e.from_id = ? THEN e.to_id ELSE e.from_id END "
    "WHERE (e.from_id = ? OR e.to_id = ?) "
    "AND e.deleted_at IS NULL AND n.deleted_at IS NULL"
)
# Deliberately NOT joined back to `nodes`: this oracle must still return the
# phantom id of a dangling endpoint, which is the whole subject of
# `test_pr6b_dangling_endpoint_no_longer_burns_a_neighbor_slot`. Node-level
# liveness is applied by each test through `_live_node_ids`.
_ORACLE_NEIGHBOR_IDS = (
    "SELECT DISTINCT CASE WHEN from_id = ? THEN to_id ELSE from_id END AS nid "
    "FROM edges WHERE (from_id = ? OR to_id = ?) AND deleted_at IS NULL"
)
_ORACLE_NEIGHBORHOOD_EDGES = (
    "SELECT e.id, e.from_id, e.to_id, e.kind FROM edges e "
    "JOIN nodes s ON s.id = e.from_id JOIN nodes d ON d.id = e.to_id "
    "WHERE (e.from_id = ? OR e.to_id = ?) "
    "AND e.deleted_at IS NULL AND s.deleted_at IS NULL AND d.deleted_at IS NULL"
)



def _live_node_ids(c) -> set[int]:
    """Node ids a user can still reach: the row exists AND is not tombstoned.

    PR7 added the second half. Before it, "live" only had to mean "the row is
    still there", because the only way to stop being live was to be deleted.
    """
    return {
        r["id"]
        for r in c.execute("SELECT id FROM nodes WHERE deleted_at IS NULL").fetchall()
    }


@pytest.fixture
def pr6b_graph(pr6a_graph):
    """`pr6a_graph` plus the conversation provenance the dashboard reads.

    Reuses the shared PR6a fixture (self-edge, duplicate edges between the same
    pair, a tombstoned endpoint and a dangling one) rather than building a
    parallel graph, and adds what only dashboard.py touches: a conversation
    node with a `conversations` row bridged to it, and edges from that node to
    both facts plus one non-fact (which must NOT surface as a fact id).
    """
    from axi import store

    ids = dict(pr6a_graph)
    ids["conv"] = store.add_node("conversation", "turno de conversación")
    store.add_edge(ids["conv"], ids["fact_bp"], "mentions")
    store.add_edge(ids["conv"], ids["fact_os"], "mentions")
    store.add_edge(ids["conv"], ids["ana"], "mentions")  # person, not a fact
    c = store._connect()  # noqa: SLF001
    c.execute(
        "INSERT INTO conversations (ts, user_text, axi_text, session_id, node_id) "
        "VALUES (?, ?, ?, ?, ?)",
        (1.0, "¿qué sabes de mí?", "bastante", "s1", ids["conv"]),
    )
    return ids


class _RecordingConn:
    """Delegating proxy that records every SQL statement an endpoint executes.

    Used instead of re-typing the production query into the test: the plan
    assertions below run EXPLAIN QUERY PLAN on the bytes dashboard.py actually
    sent, so they cannot drift away from the code they claim to measure.
    """

    def __init__(self, conn, sink):
        self._conn = conn
        self._sink = sink

    def execute(self, sql, *args, **kwargs):
        self._sink.append((sql, args[0] if args else ()))
        return self._conn.execute(sql, *args, **kwargs)

    def __getattr__(self, name):
        return getattr(self._conn, name)


@pytest.fixture
def sql_sink(monkeypatch):
    from axi import dashboard, store

    sink: list[tuple[str, object]] = []
    real_connect = store._connect  # noqa: SLF001
    monkeypatch.setattr(
        dashboard.store, "_connect", lambda: _RecordingConn(real_connect(), sink)
    )
    return sink


def _edge_plans(sink):
    """EXPLAIN QUERY PLAN for every recorded SELECT that reads the edges table."""
    from axi import store

    c = store._connect()  # noqa: SLF001
    out = []
    for sql, args in sink:
        if not sql.lstrip().upper().startswith("SELECT"):
            continue
        if " edges" not in sql:
            continue
        rows = c.execute("EXPLAIN QUERY PLAN " + sql, args).fetchall()
        out.append((sql, "\n".join(r[3] for r in rows)))
    return out


# ── 6b.1 / 6b.2 — site 1: /api/conversations fact ids ────────────────────────

def test_pr6b_conversation_fact_ids_identical_to_pre_rewrite_oracle(client, pr6b_graph):
    from axi import store

    c = store._connect()  # noqa: SLF001
    expected = [
        int(r["to_id"])
        for r in c.execute(_ORACLE_CONV_FACT_IDS, (pr6b_graph["conv"],)).fetchall()
    ]
    assert expected, "fixture must produce at least one fact edge"

    rows = client.get("/api/conversations").json()
    assert len(rows) == 1
    assert sorted(rows[0]["fact_ids"]) == sorted(expected)


def test_pr6b_conversation_fact_query_still_uses_an_edge_index(client, pr6b_graph, sql_sink):
    """INDEX PARITY: the old join seeked idx_edges_from; the new one must seek
    idx_edges_src. A silent degradation to a full scan is the exact failure
    PR6a caught in same_day_neighbors — no test fails, the graph just gets
    slower forever."""
    client.get("/api/conversations")
    plans = [p for sql, p in _edge_plans(sql_sink)]
    assert plans, "no edges query was recorded"
    joined = "\n".join(plans)
    assert "idx_edges_src" in joined, joined
    assert "SCAN e\n" not in joined + "\n" and "SCAN edges" not in joined, joined


# ── 6b.1 / 6b.2 — site 2: /api/graph/full edges ──────────────────────────────

def test_pr6b_graph_full_edges_identical_to_pre_rewrite_oracle(client, pr6b_graph):
    from axi import store

    c = store._connect()  # noqa: SLF001
    live_ids = _live_node_ids(c)
    expected = {
        (r["id"], r["from_id"], r["to_id"], r["kind"])
        for r in c.execute(_ORACLE_ALL_EDGES).fetchall()
        # the endpoint has always dropped edges whose endpoints are not in the
        # returned node set; a dangling endpoint is exactly that case
        if r["from_id"] in live_ids and r["to_id"] in live_ids
    }

    got = client.get("/api/graph/full").json()
    a_edges = {
        (e["id"], e["source"], e["target"], e["kind"])
        for e in got["edges"]
        if e["system"] == "A"
    }
    assert a_edges == expected
    # duplicate edges between the same pair must stay duplicated: a uuid join
    # must not collapse them
    assert len([e for e in got["edges"] if e["system"] == "A"]) == len(expected)


# ── 6b.1 / 6b.2 — site 3: /api/graph/node/{id} ───────────────────────────────

@pytest.mark.parametrize("role", ["hub", "fact_bp", "fact_os", "orphan", "ana"])
def test_pr6b_node_detail_identical_to_pre_rewrite_oracle(client, pr6b_graph, role):
    from axi import store
    from axi.recall import _STRUCTURAL_EDGE_KINDS

    node_id = pr6b_graph[role]
    c = store._connect()  # noqa: SLF001
    oracle = c.execute(
        _ORACLE_EDGES_TOUCHING_NODE, (node_id, node_id, node_id)
    ).fetchall()

    exp_relations = {
        (r["eid"], r["oid"], r["olabel"], r["okind"], r["ekind"],
         "out" if r["from_id"] == node_id else "in")
        for r in oracle
        if r["ekind"] and r["ekind"] not in _STRUCTURAL_EDGE_KINDS
    }
    exp_facts = {
        r["oid"] for r in oracle
        if (r["ekind"] or "") in ("mentions", "about") and r["okind"] == "fact"
    }

    got = client.get(f"/api/graph/node/{node_id}").json()
    assert {
        (r["edge_id"], r["other_id"], r["other_label"], r["other_kind"],
         r["kind"], r["direction"])
        for r in got["relations"]
    } == exp_relations
    assert {f["id"] for f in got["facts"]} == exp_facts


def test_pr6b_node_detail_keeps_the_multi_index_or_plan(client, pr6b_graph, sql_sink):
    """INDEX PARITY: the old predicate `from_id = ? OR to_id = ?` was served by
    a MULTI-INDEX OR over idx_edges_from/idx_edges_to. The rewritten predicate
    must be served the same way over idx_edges_src/idx_edges_dst."""
    client.get(f"/api/graph/node/{pr6b_graph['hub']}")
    joined = "\n".join(p for _sql, p in _edge_plans(sql_sink))
    assert "MULTI-INDEX OR" in joined, joined
    assert "idx_edges_src" in joined and "idx_edges_dst" in joined, joined
    assert "SCAN e" not in joined and "SCAN edges" not in joined, joined


# ── 6b.1 / 6b.2 — site 4: /api/graph/node/{id}/neighborhood ──────────────────

def test_pr6b_neighborhood_identical_to_pre_rewrite_oracle(client, pr6b_graph):
    from axi import store

    node_id = pr6b_graph["hub"]
    c = store._connect()  # noqa: SLF001
    live_ids = _live_node_ids(c)
    oracle_neigh = [
        r["nid"]
        for r in c.execute(_ORACLE_NEIGHBOR_IDS, (node_id,) * 3).fetchall()
        if r["nid"] != node_id and r["nid"] in live_ids
    ]
    got = client.get(f"/api/graph/node/{node_id}/neighborhood").json()
    assert {n["id"] for n in got["nodes"]} == set(oracle_neigh) | {node_id}

    in_set = {n["id"] for n in got["nodes"]}
    exp_edges = {
        (r["id"], r["from_id"], r["to_id"], r["kind"])
        for r in c.execute(_ORACLE_NEIGHBORHOOD_EDGES, (node_id, node_id)).fetchall()
        if r["from_id"] in in_set and r["to_id"] in in_set
    }
    assert {
        (e["id"], e["source"], e["target"], e["kind"]) for e in got["edges"]
    } == exp_edges


def test_pr6b_neighborhood_keeps_the_multi_index_or_plan(client, pr6b_graph, sql_sink):
    client.get(f"/api/graph/node/{pr6b_graph['hub']}/neighborhood")
    plans = _edge_plans(sql_sink)
    assert len(plans) >= 2, plans
    for sql, plan in plans:
        assert "MULTI-INDEX OR" in plan, (sql, plan)
        assert "idx_edges_src" in plan and "idx_edges_dst" in plan, (sql, plan)
        assert "SCAN e" not in plan and "SCAN edges" not in plan, (sql, plan)


def test_pr6b_neighbor_order_is_pinned_because_the_list_is_truncated(
    client, pr6b_graph, monkeypatch
):
    """ORDER-BY CONTRACT: `neighbor_ids[:_NEIGHBORHOOD_CAP]` truncates an
    unordered query, so before this rewrite the query planner decided WHICH
    neighbors the user saw. The rewrite changes the plan, so the truncation
    would have silently started keeping different nodes. The order is pinned to
    ascending node id — which is what the DISTINCT temp b-tree happened to
    produce before, so the pin preserves today's behaviour instead of changing
    it.

    PR7 changed the arithmetic, not the claim: the hub's tombstoned neighbour
    is no longer a neighbour, so the fixture has one fewer live neighbour than
    it did. The cap is therefore derived from the fixture rather than hardcoded
    at 2 — the property under test is "the LOWEST ids survive truncation", and
    hardcoding a count made that property hostage to the fixture's size."""
    from axi import dashboard

    from axi import store

    node_id = pr6b_graph["hub"]
    c = store._connect()  # noqa: SLF001
    live_ids = _live_node_ids(c)
    live_neighbors = sorted(
        r["nid"]
        for r in c.execute(_ORACLE_NEIGHBOR_IDS, (node_id,) * 3).fetchall()
        if r["nid"] != node_id and r["nid"] in live_ids
    )
    assert len(live_neighbors) >= 2, "fixture must have something to truncate"
    cap = len(live_neighbors) - 1
    monkeypatch.setattr(dashboard, "_NEIGHBORHOOD_CAP", cap)

    got = client.get(f"/api/graph/node/{node_id}/neighborhood").json()
    assert got["truncated"] is True
    kept = sorted(n["id"] for n in got["nodes"] if n["id"] != node_id)
    # the LOWEST live neighbour ids — pinned, not whatever the plan emits
    assert kept == live_neighbors[:cap]
    again = client.get(f"/api/graph/node/{node_id}/neighborhood").json()
    assert [n["id"] for n in again["nodes"]] == [n["id"] for n in got["nodes"]]


def test_pr6b_dangling_endpoint_no_longer_burns_a_neighbor_slot(
    client, pr6b_graph, monkeypatch
):
    """DOCUMENTED BEHAVIOUR CHANGE, asserted rather than hidden.

    `pr6a_graph` keeps a "ghost" edge whose endpoint node row is gone (legal in
    mobile's model — an edge may sync before its node). The old integer query
    returned that phantom id: it counted toward `_NEIGHBORHOOD_CAP`, could flip
    `truncated` to True with one fewer real neighbour, and resolved to no node
    row, so the client never rendered it. Resolving through `dst_uuid` drops it
    at the query. PR6b takes option (a), consistent with PR6a: no from_id/to_id
    fallback — the phantom is gone, and that is a fix, not a loss.

    The cap is patched to exactly the number of LIVE neighbours, which is where
    the difference is observable: the phantom used to push the count over the
    cap, so the user lost a real neighbour and got `truncated: true` for a node
    that was not actually truncated."""
    from axi import dashboard, store

    node_id = pr6b_graph["hub"]
    c = store._connect()  # noqa: SLF001
    oracle_ids = {
        r["nid"]
        for r in c.execute(_ORACLE_NEIGHBOR_IDS, (node_id,) * 3).fetchall()
        if r["nid"] != node_id
    }
    live_ids = _live_node_ids(c)
    phantoms = oracle_ids - live_ids
    assert phantoms, "fixture must carry at least one dangling endpoint"

    monkeypatch.setattr(dashboard, "_NEIGHBORHOOD_CAP", len(oracle_ids & live_ids))
    got = client.get(f"/api/graph/node/{node_id}/neighborhood").json()
    assert not (phantoms & {n["id"] for n in got["nodes"]})
    assert {n["id"] for n in got["nodes"]} == (oracle_ids & live_ids) | {node_id}
    assert got["truncated"] is False


# ── 6b.2 — no old-column SQL left behind ─────────────────────────────────────

def test_pr6b_dashboard_has_no_sql_left_on_from_id_to_id_or_edge_kind():
    """Every dashboard read of axi's own edges table must be off the columns
    PR8 deletes. Fails loudly if a new one is introduced."""
    import pathlib

    from axi import dashboard

    src = pathlib.Path(dashboard.__file__).read_text(encoding="utf-8")
    offenders = [
        (i, line)
        for i, line in enumerate(src.splitlines(), 1)
        if ("from_id" in line or "to_id" in line)
        # lifeos.db has its own edges table with src_id/dst_id/rel — out of
        # scope by design (design-schema.md Decision 3), and it uses neither name
    ]
    assert offenders == [], offenders


def test_pr6b_node_without_uuid_is_refused_loudly_and_names_the_node(client, pr6b_graph):
    """A uuid-less node matches no edge, so both node endpoints would answer
    "no relations" with a 200 — a wrong answer that looks like an empty graph.
    PR6a chose option (a) (NULL is impossible and reaching it is loud); this is
    the same choice at the read boundary. The message must name the node id:
    a guard that fires and identifies nothing sends you to a debugger against a
    database you may not be able to reproduce (PR6a, task 6a.8)."""
    from axi import store

    node_id = pr6b_graph["ana"]
    c = store._connect()  # noqa: SLF001
    c.execute("UPDATE nodes SET uuid = NULL WHERE id = ?", (node_id,))

    for path in (f"/api/graph/node/{node_id}", f"/api/graph/node/{node_id}/neighborhood"):
        r = client.get(path)
        assert r.status_code == 500, path
        detail = r.json()["detail"]
        assert f"id={node_id}" in detail, detail
        assert "uuid" in detail, detail


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — task 7.9b: tombstone invisibility asserted at the HTTP BOUNDARY.
#
# 7.9 proves it in `test_store.py`, one layer down. That is not enough: PR7
# could go green with the store fully tombstone-aware while a deleted memory
# still renders in the graph browser and in the 3D brain, because these four
# endpoints build their own SQL. The endpoints are what the user looks at.
#
# Every case tombstones the row DIRECTLY rather than through `delete_node`, so
# the assertion is about the READ FILTER and not about the row having been
# removed — see the same note in test_store.py.
# ═══════════════════════════════════════════════════════════════════════════


@pytest.fixture
def pr7_graph(pr6b_graph):
    """`pr6b_graph` with nothing tombstoned yet — each test picks its victim."""
    return pr6b_graph


def _tombstone_node(nid):
    import time as _t

    from axi import store

    store._connect().execute(  # noqa: SLF001
        "UPDATE nodes SET deleted_at=? WHERE id=?", (_t.time(), nid)
    )


def _tombstone_edges_between(src_id, dst_id):
    """Tombstone every live edge between two nodes; returns how many."""
    import time as _t

    from axi import store

    c = store._connect()  # noqa: SLF001
    cur = c.execute(
        "UPDATE edges SET deleted_at=?, updated_at=? WHERE "
        "src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND "
        "dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND deleted_at IS NULL",
        (_t.time(), _t.time(), src_id, dst_id),
    )
    return cur.rowcount


# ── site 1: /api/conversations fact ids ──────────────────────────────────────

def test_pr7_conversation_fact_ids_hide_a_tombstoned_fact(client, pr7_graph):
    body = client.get("/api/conversations").json()
    ids = {i for row in body for i in row["fact_ids"]}
    assert pr7_graph["fact_os"] in ids

    _tombstone_node(pr7_graph["fact_os"])

    body = client.get("/api/conversations").json()
    ids = {i for row in body for i in row["fact_ids"]}
    assert pr7_graph["fact_os"] not in ids, (
        "a deleted memory is still listed as a fact of this conversation"
    )
    assert pr7_graph["fact_bp"] in ids, "live facts must be unaffected"


def test_pr7_conversation_fact_ids_hide_a_tombstoned_edge(client, pr7_graph):
    assert _tombstone_edges_between(pr7_graph["conv"], pr7_graph["fact_os"]) == 1

    body = client.get("/api/conversations").json()
    ids = {i for row in body for i in row["fact_ids"]}
    assert pr7_graph["fact_os"] not in ids
    assert pr7_graph["fact_bp"] in ids


# ── site 2: /api/graph/full ──────────────────────────────────────────────────

def test_pr7_graph_full_hides_a_tombstoned_node_and_its_edges(client, pr7_graph):
    body = client.get("/api/graph/full").json()
    assert pr7_graph["ana"] in {n["id"] for n in body["nodes"]}

    _tombstone_node(pr7_graph["ana"])
    body = client.get("/api/graph/full").json()

    assert pr7_graph["ana"] not in {n["id"] for n in body["nodes"]}, (
        "the 3D brain still renders a deleted memory"
    )
    touching = [
        e for e in body["edges"]
        if pr7_graph["ana"] in (e["source"], e["target"])
    ]
    assert touching == [], f"edges to a deleted node survived: {touching}"


def test_pr7_graph_full_hides_a_tombstoned_edge_between_live_nodes(client, pr7_graph):
    hub, ana = pr7_graph["hub"], pr7_graph["ana"]
    assert _tombstone_edges_between(hub, ana) == 1

    body = client.get("/api/graph/full").json()
    assert hub in {n["id"] for n in body["nodes"]}
    assert ana in {n["id"] for n in body["nodes"]}
    assert [
        e for e in body["edges"] if (e["source"], e["target"]) == (hub, ana)
    ] == [], "a deleted relation is still drawn between two live nodes"


def test_pr7_graph_full_already_hid_the_fixtures_tombstoned_node(client, pr7_graph):
    """`pr6a_graph` ships a node tombstoned at build time.

    PR6a deliberately left it visible ("PR7 does the filtering"). This is the
    assertion that flips, stated on its own so the change of expectation is
    visible rather than buried inside another test's set comparison.
    """
    body = client.get("/api/graph/full").json()
    assert pr7_graph["tombstoned"] not in {n["id"] for n in body["nodes"]}


# ── site 3: /api/graph/node/{id} ─────────────────────────────────────────────

def test_pr7_node_detail_404s_for_a_tombstoned_node(client, pr7_graph):
    assert client.get(f"/api/graph/node/{pr7_graph['ana']}").status_code == 200
    _tombstone_node(pr7_graph["ana"])
    r = client.get(f"/api/graph/node/{pr7_graph['ana']}")
    assert r.status_code == 404, (
        "the node browser still opens a deleted memory"
    )


def test_pr7_node_detail_hides_a_tombstoned_neighbour(client, pr7_graph):
    hub = pr7_graph["hub"]
    body = client.get(f"/api/graph/node/{hub}").json()
    assert pr7_graph["ana"] in {r["other_id"] for r in body["relations"]}

    _tombstone_node(pr7_graph["ana"])
    body = client.get(f"/api/graph/node/{hub}").json()
    assert pr7_graph["ana"] not in {r["other_id"] for r in body["relations"]}


def test_pr7_node_detail_hides_a_tombstoned_fact_edge(client, pr7_graph):
    """The `facts` lane is built from the same rows and must filter too."""
    fact_bp = pr7_graph["fact_bp"]
    body = client.get(f"/api/graph/node/{fact_bp}").json()
    assert body["node"]["id"] == fact_bp

    hub = pr7_graph["hub"]
    body = client.get(f"/api/graph/node/{hub}").json()
    assert fact_bp in {f["id"] for f in body["facts"]}

    assert _tombstone_edges_between(hub, fact_bp) == 1
    body = client.get(f"/api/graph/node/{hub}").json()
    assert fact_bp not in {f["id"] for f in body["facts"]}


# ── site 4: /api/graph/node/{id}/neighborhood ────────────────────────────────

def test_pr7_neighborhood_404s_for_a_tombstoned_centre(client, pr7_graph):
    _tombstone_node(pr7_graph["ana"])
    r = client.get(f"/api/graph/node/{pr7_graph['ana']}/neighborhood")
    assert r.status_code == 404


def test_pr7_neighborhood_hides_a_tombstoned_neighbour(client, pr7_graph):
    hub = pr7_graph["hub"]
    body = client.get(f"/api/graph/node/{hub}/neighborhood").json()
    assert pr7_graph["ana"] in {n["id"] for n in body["nodes"]}

    _tombstone_node(pr7_graph["ana"])
    body = client.get(f"/api/graph/node/{hub}/neighborhood").json()
    assert pr7_graph["ana"] not in {n["id"] for n in body["nodes"]}, (
        "the 3D brain still shows a deleted memory as a neighbour"
    )
    assert [
        e for e in body["edges"] if pr7_graph["ana"] in (e["source"], e["target"])
    ] == []


def test_pr7_neighborhood_hides_a_tombstoned_edge(client, pr7_graph):
    hub, ana = pr7_graph["hub"], pr7_graph["ana"]
    assert _tombstone_edges_between(hub, ana) == 1

    body = client.get(f"/api/graph/node/{hub}/neighborhood").json()
    assert [
        e for e in body["edges"] if (e["source"], e["target"]) == (hub, ana)
    ] == [], "a deleted relation is still drawn in the neighbourhood view"


def test_pr7_delete_node_endpoint_is_idempotent_and_404s_on_the_second_call(client, pr7_graph):
    """The user-facing delete path, end to end.

    The first DELETE tombstones; the second must report 404 rather than
    claiming to have deleted the memory again. This is also the only test that
    exercises the whole tombstone write path through HTTP.
    """
    ana = pr7_graph["ana"]
    assert client.delete(f"/api/graph/node/{ana}").status_code == 200
    assert client.get(f"/api/graph/node/{ana}").status_code == 404
    assert client.delete(f"/api/graph/node/{ana}").status_code == 404
