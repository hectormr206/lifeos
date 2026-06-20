"""Slice 2 TDD tests — Service-lifecycle events via obs.managed_systemctl.

Coverage:
- 2.1 dashboard stop (non-4B): calls obs.managed_systemctl with caller="model-activate",
       reason=f"activating {model_id} (non-4B)" and records an event BEFORE systemctl.
- 2.2 dashboard restart (4B): calls obs.managed_systemctl with caller="model-activate",
       reason="4B pair co-start".
- 2.3 models_manager._systemctl_restart_llama: calls obs.managed_systemctl with
       caller="models_manager.set_active", reason="brain swap".
- 2.4 nano_manager._systemctl_restart_nano: calls obs.managed_systemctl with
       caller="nano_manager", reason="nano swap".
- 2.5 embed_manager.restart_embed_service: calls obs.managed_systemctl with
       caller="embed_manager", reason="embed model swap".
- 2.6 tray._restart_daemon: calls obs.managed_systemctl with
       caller="tray", reason="tray restart".

Regression:
- Existing returncode/health-probe/error handling is preserved in each site.
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import MagicMock, call, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fake_completed(returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout="", stderr=""
    )


# ---------------------------------------------------------------------------
# 2.1 RED — dashboard stop (non-4B) records event via obs.managed_systemctl
# ---------------------------------------------------------------------------

def test_dashboard_stop_emits_event_before_systemctl(tmp_path, monkeypatch):
    """Activating a non-4B model calls obs.managed_systemctl (not bare subprocess.run)
    with caller='model-activate' and an appropriate reason before the VT stop.
    """
    from axi import dashboard, models_catalog, models_manager, obs

    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)

    # Standard dashboard stubs
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *a, **k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 12000, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 1, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)
    dashboard._models_progress.clear()

    # Make the model appear installed
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")

    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)
    # Also patch the dashboard module's reference if it imported obs directly
    monkeypatch.setattr(dashboard, "obs", obs)

    from fastapi.testclient import TestClient
    client = TestClient(dashboard.app)
    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 200

    # At least one call to managed_systemctl for the VT stop
    stop_calls = [c for c in calls if c["action"] == "stop" and c["service"] == "llama-vt.service"]
    assert stop_calls, f"Expected managed_systemctl stop call, got: {calls}"
    assert stop_calls[0]["caller"] == "model-activate"
    # reason should reference the model_id being activated (non-4B)
    assert "gemma4-e2b-it" in stop_calls[0]["reason"] or "non-4B" in stop_calls[0]["reason"], (
        f"reason should mention the model or 'non-4B', got: {stop_calls[0]['reason']}"
    )


def test_dashboard_4b_restart_emits_event(tmp_path, monkeypatch):
    """Activating qwen35-4b calls obs.managed_systemctl for the VT restart
    with caller='model-activate' and reason='4B pair co-start'.
    """
    from axi import dashboard, models_catalog, models_manager, obs

    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *a, **k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 12000, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 1, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)
    dashboard._models_progress.clear()

    # Install qwen35-4b + vibethinker-3b (needed for vt_entry lookup)
    for mid in ("qwen35-4b", "vibethinker-3b"):
        entry = models_catalog.by_id(mid)
        for f in entry.files:
            p = models_manager.expected_path(entry, f)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"x")

    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)
    monkeypatch.setattr(dashboard, "obs", obs)

    from fastapi.testclient import TestClient
    client = TestClient(dashboard.app)
    r = client.post("/api/models/qwen35-4b/activate")
    assert r.status_code == 200

    restart_calls = [
        c for c in calls
        if c["action"] == "restart" and c["service"] == "llama-vt.service"
    ]
    assert restart_calls, f"Expected managed_systemctl restart call for VT, got: {calls}"
    assert restart_calls[0]["caller"] == "model-activate"
    assert restart_calls[0]["reason"] == "4B pair co-start"


# ---------------------------------------------------------------------------
# 2.3 RED — models_manager._systemctl_restart_llama records event
# ---------------------------------------------------------------------------

def test_models_manager_restart_emits_event(monkeypatch):
    """_systemctl_restart_llama calls obs.managed_systemctl with
    caller='models_manager.set_active' and reason='brain swap'.
    """
    from axi import models_manager, obs

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)

    models_manager._systemctl_restart_llama()

    assert len(calls) == 1, f"Expected 1 call to managed_systemctl, got: {calls}"
    c = calls[0]
    assert c["action"] == "restart"
    assert c["service"] == "llama-server.service"
    assert c["caller"] == "models_manager.set_active"
    assert c["reason"] == "brain swap"


def test_models_manager_restart_check_raises_on_failure(monkeypatch):
    """_systemctl_restart_llama keeps check=True behavior: CalledProcessError propagates."""
    from axi import models_manager, obs

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        # Simulate check=True behavior: raise if returncode != 0
        if check:
            raise subprocess.CalledProcessError(1, ["systemctl"])
        return _fake_completed(1)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)

    with pytest.raises(subprocess.CalledProcessError):
        models_manager._systemctl_restart_llama()


# ---------------------------------------------------------------------------
# 2.4 (2.5) RED — nano_manager._systemctl_restart_nano records event
# ---------------------------------------------------------------------------

def test_nano_manager_restart_emits_event(monkeypatch):
    """_systemctl_restart_nano calls obs.managed_systemctl with
    caller='nano_manager' and reason='nano swap'.
    """
    from axi import nano_manager, obs

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)

    nano_manager._systemctl_restart_nano()

    assert len(calls) == 1
    c = calls[0]
    assert c["action"] == "restart"
    assert c["service"] == "llama-nano.service"
    assert c["caller"] == "nano_manager"
    assert c["reason"] == "nano swap"


# ---------------------------------------------------------------------------
# 2.5 (2.6) RED — embed_manager.restart_embed_service records event
# ---------------------------------------------------------------------------

def test_embed_manager_restart_emits_event(monkeypatch):
    """restart_embed_service calls obs.managed_systemctl with
    caller='embed_manager' and reason='embed model swap'.
    """
    from axi import embed_manager, obs

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)

    embed_manager.restart_embed_service()

    assert len(calls) == 1
    c = calls[0]
    assert c["action"] == "restart"
    assert c["service"] == "llama-embed.service"
    assert c["caller"] == "embed_manager"
    assert c["reason"] == "embed model swap"


# ---------------------------------------------------------------------------
# 2.6 (2.7) RED — tray._restart_daemon records event
# ---------------------------------------------------------------------------

def test_tray_restart_daemon_emits_event(monkeypatch):
    """_restart_daemon calls obs.managed_systemctl with
    caller='tray' and reason='tray restart'.
    """
    # tray.py imports PySide6 which may not be installed in CI.
    # We patch the import to avoid issues and test the function directly.
    pytest.importorskip("PySide6")

    from axi import obs
    import axi.tray as tray_mod

    calls: list[dict] = []

    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        calls.append({"action": action, "service": service, "caller": caller, "reason": reason})
        return _fake_completed(0)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)

    # _restart_daemon is an instance method; call it on a minimal stub
    class _MinimalTray:
        def _restart_daemon(self):
            return tray_mod.AxiTray._restart_daemon(self)

    _MinimalTray()._restart_daemon()

    assert len(calls) == 1
    c = calls[0]
    assert c["action"] == "restart"
    assert c["service"] == "axi-voice.service"
    assert c["caller"] == "tray"
    assert c["reason"] == "tray restart"


# ---------------------------------------------------------------------------
# Regression: returncode handling preserved
# ---------------------------------------------------------------------------

def test_dashboard_stop_returncode_503_when_vt_still_up(tmp_path, monkeypatch):
    """If managed_systemctl returns non-zero AND VT health probe responds,
    the endpoint must raise 503 (existing behavior preserved).
    """
    from axi import dashboard, models_catalog, models_manager, obs
    import urllib.error

    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *a, **k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 12000, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 1, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)
    dashboard._models_progress.clear()

    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")

    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)

    # managed_systemctl returns failure for stop
    def fake_managed_systemctl(action, service, *, caller, reason, check=False, timeout=30):
        return _fake_completed(1)

    monkeypatch.setattr(obs, "managed_systemctl", fake_managed_systemctl)
    monkeypatch.setattr(dashboard, "obs", obs)

    # Health probe: VT responds (so it's still up → 503)
    class _FakeResp:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): pass

    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **kw: _FakeResp())

    from fastapi.testclient import TestClient
    client = TestClient(dashboard.app)
    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 503
    assert "503" in str(r.status_code)
