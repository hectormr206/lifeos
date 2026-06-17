"""TDD tests for the wakeword_status daemon command and snapshot field.

RED phase: these tests MUST FAIL before implementation.
GREEN phase: pass after daemon.py and dashboard.py are updated.
"""
from __future__ import annotations

import pytest
from axi.daemon import Daemon, _handle_cmd
from axi.memory import ConversationMemory


# ───────── Fakes (mirrors test_daemon.py helpers) ─────────

class FakeRecorder:
    def __init__(self):
        self._recording = False
        self.active_source = "fake"

    @property
    def is_recording(self) -> bool:
        return self._recording

    def start(self) -> str:
        self._recording = True
        return self.active_source

    def stop(self):
        self._recording = False
        import numpy as np
        return (0.05 * np.sin(2 * 3.14159 * 220.0 * (
            __import__("numpy").arange(16000, dtype="float32") / 16000
        ))).astype("float32")


class FakeTranscriber:
    def transcribe(self, audio):
        return "test", "es", 0.9


class FakeBrainAsk:
    def __call__(self, *a, **kw):
        return "ok"


class FakeMeetingSession:
    def __init__(self, **kw):
        self.meeting_id = 99
    def start(self): return 99
    def stop(self): return 99
    def status_summary(self): return {"meeting_id": 99, "duration_s": 0, "mic_chunks": 0, "system_chunks": 0, "screens": 0}
    def register_dictation(self, *a, **kw): pass


def _build(**overrides) -> Daemon:
    kwargs = {
        "recorder": FakeRecorder(),
        "transcriber": FakeTranscriber(),
        "memory": ConversationMemory(),
        "brain_ask": FakeBrainAsk(),
        "vision_capture": lambda: None,
        "eyes_capture": lambda: (None, "ok"),
        "meeting_factory": lambda **kw: FakeMeetingSession(**kw),
    }
    kwargs.update(overrides)
    return Daemon(**kwargs)


# ───────── Tests: wakeword_status command ─────────

def test_wakeword_status_inactive_when_no_listener():
    """wakeword_status returns 'inactive' when _wakeword_listener is None."""
    d = _build()
    d._wakeword_listener = None  # explicitly ensure it's None
    resp, quit_ = _handle_cmd(d, "wakeword_status")
    assert resp == "inactive"
    assert quit_ is False


def test_wakeword_status_active_when_listener_set():
    """wakeword_status returns 'active' when _wakeword_listener is not None."""
    d = _build()
    d._wakeword_listener = object()  # any non-None object simulates a live listener
    resp, quit_ = _handle_cmd(d, "wakeword_status")
    assert resp == "active"
    assert quit_ is False


def test_wakeword_status_active_after_manual_assignment():
    """Assigning a sentinel to _wakeword_listener flips status to active."""
    d = _build()
    assert not getattr(d, "_wakeword_listener", None)
    sentinel = object()
    d._wakeword_listener = sentinel
    resp, _ = _handle_cmd(d, "wakeword_status")
    assert resp == "active"
    d._wakeword_listener = None
    resp2, _ = _handle_cmd(d, "wakeword_status")
    assert resp2 == "inactive"


# ───────── Tests: snapshot wakeword_listening field ─────────

@pytest.fixture
def client_wakeword_active(monkeypatch):
    """Dashboard test client where daemon reports wakeword active."""
    from axi import dashboard

    def _daemon_cmd_wakeword_active(cmd, **kw):
        if cmd == "wakeword_status":
            return "active"
        if cmd == "meeting_status":
            return "idle"
        return "idle"

    monkeypatch.setattr(dashboard, "_daemon_cmd", _daemon_cmd_wakeword_active)
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **kw: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {"name": "test", "used_mb": 0, "total_mb": 0, "util_pct": 0})
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {"used": 0, "total": 1, "pct": 0.0})
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)

    from fastapi.testclient import TestClient
    return TestClient(dashboard.app)


@pytest.fixture
def client_wakeword_inactive(monkeypatch):
    """Dashboard test client where daemon reports wakeword inactive."""
    from axi import dashboard

    def _daemon_cmd_wakeword_inactive(cmd, **kw):
        if cmd == "wakeword_status":
            return "inactive"
        if cmd == "meeting_status":
            return "idle"
        return "idle"

    monkeypatch.setattr(dashboard, "_daemon_cmd", _daemon_cmd_wakeword_inactive)
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **kw: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {"name": "test", "used_mb": 0, "total_mb": 0, "util_pct": 0})
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {"used": 0, "total": 1, "pct": 0.0})
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)

    from fastapi.testclient import TestClient
    return TestClient(dashboard.app)


@pytest.fixture
def client_daemon_error(monkeypatch):
    """Dashboard test client where daemon call errors (returns empty string)."""
    from axi import dashboard

    def _daemon_cmd_error(cmd, **kw):
        if cmd == "wakeword_status":
            return ""   # simulate timeout/error
        if cmd == "meeting_status":
            return "idle"
        return "idle"

    monkeypatch.setattr(dashboard, "_daemon_cmd", _daemon_cmd_error)
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **kw: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {"name": "test", "used_mb": 0, "total_mb": 0, "util_pct": 0})
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {"used": 0, "total": 1, "pct": 0.0})
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)

    from fastapi.testclient import TestClient
    return TestClient(dashboard.app)


def test_snapshot_includes_wakeword_listening_field(client_wakeword_active):
    """snapshot() includes wakeword_listening boolean field."""
    r = client_wakeword_active.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert "wakeword_listening" in data, "snapshot must expose wakeword_listening field"


def test_snapshot_wakeword_listening_true_when_active(client_wakeword_active):
    """snapshot() sets wakeword_listening=True when daemon reports active."""
    r = client_wakeword_active.get("/api/snapshot")
    data = r.json()
    assert data["wakeword_listening"] is True


def test_snapshot_wakeword_listening_false_when_inactive(client_wakeword_inactive):
    """snapshot() sets wakeword_listening=False when daemon reports inactive."""
    r = client_wakeword_inactive.get("/api/snapshot")
    data = r.json()
    assert data["wakeword_listening"] is False


def test_snapshot_wakeword_listening_false_on_daemon_error(client_daemon_error):
    """snapshot() defaults wakeword_listening=False when daemon errors/times out."""
    r = client_daemon_error.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    assert data["wakeword_listening"] is False, "must default to False on error, not break snapshot"
