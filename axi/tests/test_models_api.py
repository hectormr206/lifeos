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
    # 5 models: qwen36-35b-a3b (prod/quality) + gemma4-e2b-it (small/fast/vision)
    # + qwen35-2b (game co-pilot brain, added 2026-06-17)
    # + qwen35-4b (primary triad brain, added 2026-06-18)
    # + vibethinker-3b (reasoning sibling, added 2026-06-18).
    assert {"qwen36-35b-a3b", "gemma4-e2b-it", "qwen35-2b"} <= ids
    assert "qwen35-4b" in ids      # triad primary brain
    assert "vibethinker-3b" in ids  # triad reasoning sibling
    # Cut models must be absent.
    assert "gemma4-e4b-it" not in ids
    assert "gemma4-26b-a4b-it" not in ids
    assert "nemotron3-nano-omni-30b-a3b" not in ids
    assert "qwen35-9b" not in ids
    assert "granite-4.0-h-1b" not in ids
    assert "lfm2-1.2b-extract" not in ids
    # Other Qwen3.5 dense sizes must remain absent (2B co-pilot + 4B triad are the only ones).
    assert "qwen35-0_8b" not in ids
    # Old Qwen3-VL ids must be absent.
    assert "qwen3-vl-30b-a3b" not in ids
    assert "qwen3-vl-8b" not in ids
    assert "qwen3-vl-4b" not in ids
    # Total catalog count: 5 entries (3 original + 2 triad brains)
    assert len(rows) == 5
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


# ---------------------------------------------------------------------------
# Regression: pair-activation must NOT issue real systemctl commands
# ---------------------------------------------------------------------------

def test_activate_non_4b_does_not_run_real_systemctl(
    client, monkeypatch, _block_live_system_subprocess
):
    """Activating a non-4B model triggers the pair-activation VT-stop path in
    dashboard.py (~line 2196).  The subprocess guard must intercept the
    ``systemctl --user stop llama-vt.service`` call so it NEVER reaches the
    live system.

    This is the regression test for the llama-vt drop gremlin: pytest was
    issuing a real ``systemctl stop llama-vt.service`` during every
    ``test_activate_*`` run on a non-4B model.
    """
    from axi import models_catalog, models_manager

    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")

    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)

    # _block_live_system_subprocess is the recorded list from the autouse fixture.
    recorded_before = list(_block_live_system_subprocess)

    r = client.post("/api/models/gemma4-e2b-it/activate")
    # Endpoint should succeed (guard returns returncode=0 for the stop call).
    assert r.status_code == 200

    new_recorded = _block_live_system_subprocess[len(recorded_before):]
    systemctl_stops = [
        args for args in new_recorded
        if isinstance(args, (list, tuple))
        and len(args) >= 4
        and args[0] == "systemctl"
        and "stop" in args
        and "llama-vt.service" in args
    ]
    assert systemctl_stops, (
        "Expected the subprocess guard to intercept 'systemctl --user stop "
        "llama-vt.service' during pair-activation of a non-4B model, but no "
        "such call was recorded. The gremlin may have regressed."
    )


def test_subprocess_guard_intercepts_systemctl_run():
    """Sanity: the autouse guard intercepts a direct subprocess.run systemctl
    call and returns a fake CompletedProcess without executing.
    """
    import subprocess

    # This would stop llama-vt on the real machine if not intercepted.
    result = subprocess.run(
        ["systemctl", "--user", "is-active", "llama-vt.service"],
        capture_output=True, text=True,
    )
    # Guard returns returncode=0 and empty strings — real systemctl would
    # return "active\n" or similar.  The key assertion is that it returned
    # at all (not executed) and did not shell out.
    assert isinstance(result, subprocess.CompletedProcess)
    assert result.returncode == 0
    # stdout is "" (fake) not "active" (real) — proves it was intercepted.
    assert result.stdout == ""
