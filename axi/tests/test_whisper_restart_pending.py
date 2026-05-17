"""Tests for the Whisper restart-pending indicator (PRD P2.4).

The dashboard creates a marker file when the user changes a Whisper config
key (model, beam_size, initial_prompt) from `/config`. The daemon clears
the marker on startup. `/api/snapshot` reflects it as `whisper_restart_pending`.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def state_root(tmp_path, monkeypatch):
    """Redirect XDG_STATE_HOME so the marker writes to tmp_path/axi/."""
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    return tmp_path


@pytest.fixture
def fresh_config(tmp_path, monkeypatch):
    """Point axi.config at a temp file so saves don't touch ~/.config/axi/."""
    from axi import config

    cfg_dir = tmp_path / "axi-config"
    cfg_dir.mkdir()
    monkeypatch.setattr(config, "CONFIG_DIR", cfg_dir)
    monkeypatch.setattr(config, "CONFIG_PATH", cfg_dir / "config.json")
    monkeypatch.setattr(config, "_cache", None)
    yield config
    monkeypatch.setattr(config, "_cache", None)


@pytest.fixture
def client(state_root, fresh_config, monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 0, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 0, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)
    return TestClient(dashboard.app)


def _marker_path(state_root: Path) -> Path:
    return state_root / "axi" / "whisper_restart_pending.lock"


def test_post_config_same_whisper_values_no_marker(client, state_root):
    """Submitting the current values should NOT touch the marker."""
    # Seed config with defaults (loading writes the file).
    initial = client.get("/api/config").json()
    assert not _marker_path(state_root).exists()

    # POST the same value back — no change → no marker.
    r = client.post("/api/config", json={
        "whisper_beam_size": initial["whisper_beam_size"],
        "whisper_model_name": initial["whisper_model_name"],
    })
    assert r.status_code == 200
    assert not _marker_path(state_root).exists()


def test_post_config_changes_beam_creates_marker(client, state_root):
    """A different whisper_beam_size MUST create the marker."""
    initial = client.get("/api/config").json()
    new_beam = initial["whisper_beam_size"] + 1
    r = client.post("/api/config", json={"whisper_beam_size": new_beam})
    assert r.status_code == 200, r.text
    assert _marker_path(state_root).exists()


def test_post_config_changes_initial_prompt_creates_marker(client, state_root):
    r = client.post("/api/config", json={"whisper_initial_prompt": "diferente prompt"})
    assert r.status_code == 200, r.text
    assert _marker_path(state_root).exists()


def test_post_config_changes_model_name_creates_marker(client, state_root):
    r = client.post("/api/config", json={"whisper_model_name": "small"})
    assert r.status_code == 200, r.text
    assert _marker_path(state_root).exists()


def test_unrelated_change_does_not_create_marker(client, state_root):
    """Changing a non-Whisper key must NOT trigger the pending marker."""
    r = client.post("/api/config", json={"tts_enabled": False})
    assert r.status_code == 200, r.text
    assert not _marker_path(state_root).exists()


def test_snapshot_reflects_marker(client, state_root):
    """`whisper_restart_pending` must be False without marker, True with it."""
    snap = client.get("/api/snapshot").json()
    assert snap["whisper_restart_pending"] is False

    # Create the marker manually (simulating a previous POST).
    marker = _marker_path(state_root)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("{}", encoding="utf-8")

    snap = client.get("/api/snapshot").json()
    assert snap["whisper_restart_pending"] is True


def test_daemon_startup_clears_marker(state_root, monkeypatch):
    """`_clear_whisper_restart_marker` removes a stale marker."""
    # The daemon module's marker path is computed at import time from the env
    # variable, so we monkeypatch the module-level constant for this test.
    from axi import daemon

    marker = _marker_path(state_root)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("{}", encoding="utf-8")
    assert marker.exists()

    monkeypatch.setattr(daemon, "_WHISPER_RESTART_MARKER", marker)
    daemon._clear_whisper_restart_marker()

    assert not marker.exists()


def test_daemon_clear_marker_is_idempotent(state_root, monkeypatch):
    """Clearing an already-absent marker must not raise."""
    from axi import daemon

    marker = _marker_path(state_root)
    monkeypatch.setattr(daemon, "_WHISPER_RESTART_MARKER", marker)
    # Should not raise even though file does not exist.
    daemon._clear_whisper_restart_marker()
    daemon._clear_whisper_restart_marker()
    assert not marker.exists()
