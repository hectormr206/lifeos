"""Tests for the /api/models endpoints in dashboard.py.

systemctl + huggingface are stubbed; nothing touches the live system.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(tmp_path, monkeypatch):
    from axi import dashboard, models_manager

    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)

    # Standard dashboard stubs (same as test_dashboard.py).
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

    # Clear any cross-test progress carryover (module-level dict).
    dashboard._models_progress.clear()

    return TestClient(dashboard.app)


def test_get_models_returns_catalog(client):
    r = client.get("/api/models")
    assert r.status_code == 200
    rows = r.json()
    ids = {row["id"] for row in rows}
    # 4 bench-proven KEEP models.
    assert {
        "qwen36-35b-a3b", "gemma4-e4b-it", "gemma4-e2b-it", "gemma4-26b-a4b-it",
    } <= ids
    # CUT models must be absent.
    assert "nemotron3-nano-omni-30b-a3b" not in ids
    assert "qwen35-9b" not in ids
    assert "granite-4.0-h-1b" not in ids
    assert "lfm2-1.2b-extract" not in ids
    # Removed tiny Qwen3.5 models (0.8B/2B/4B) must be absent.
    assert "qwen35-0_8b" not in ids
    assert "qwen35-2b" not in ids
    assert "qwen35-4b" not in ids
    # Old Qwen3-VL ids must be absent.
    assert "qwen3-vl-30b-a3b" not in ids
    assert "qwen3-vl-8b" not in ids
    assert "qwen3-vl-4b" not in ids
    # Total catalog count: 4 entries
    assert len(rows) == 4
    for row in rows:
        for k in ("name", "family", "params", "features", "installed", "is_active"):
            assert k in row


def test_get_active_returns_id_or_none(client):
    r = client.get("/api/models/active")
    assert r.status_code == 200
    assert "id" in r.json()


def test_progress_unknown_id_404(client):
    r = client.get("/api/models/nope/progress")
    assert r.status_code == 404


def test_progress_known_id_returns_idle(client):
    r = client.get("/api/models/gemma4-e2b-it/progress")
    assert r.status_code == 200
    assert r.json()["state"] == "idle"


def test_download_unknown_id_404(client):
    r = client.post("/api/models/nope/download")
    assert r.status_code == 404


def test_download_already_installed_returns_200(client, tmp_path):
    from axi import models_catalog, models_manager
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    r = client.post("/api/models/gemma4-e2b-it/download")
    assert r.status_code == 200
    assert r.json()["started"] is False


def test_activate_unknown_id_404(client):
    r = client.post("/api/models/nope/activate")
    assert r.status_code == 404


def test_activate_not_installed_409(client):
    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 409


def test_activate_503_when_systemctl_fails(client, monkeypatch):
    from axi import models_catalog, models_manager
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")

    def boom(*a, **k):
        raise subprocess.CalledProcessError(1, ["systemctl"])
    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", boom)

    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 503


def test_activate_503_when_health_never_comes(client, monkeypatch):
    from axi import models_catalog, models_manager
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: False)

    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 503


def test_activate_200_happy_path(client, monkeypatch):
    from axi import models_catalog, models_manager
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)

    r = client.post("/api/models/gemma4-e2b-it/activate")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["active"] == "gemma4-e2b-it"


def test_models_page_renders(client):
    r = client.get("/models")
    assert r.status_code == 200
    assert "Modelos" in r.text
