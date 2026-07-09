"""API + page tests for the on-demand self-improve goal preview.

The model path (director/VT-3B wiring) and git runner are monkeypatched so no
real subprocess, systemd unit, or HTTP call is ever touched. The whole point of
the slice is observability: a preview must NEVER start a dev run.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def _routed_git(args):
    if args[:2] == ["log", "--oneline"]:
        return "abc fix parser\n"
    if args[:2] == ["log", "--name-only"]:
        return "\nlifeos/src/lifeos/health/ingestion.py\n"
    return ""


def test_dev_runs_page_has_preview_button(client):
    r = client.get("/dev")
    assert r.status_code == 200
    assert "previewGoal" in r.text          # the Alpine handler is wired
    assert "Vista previa de objetivo" in r.text


def test_dev_runs_page_has_change_preview_ui(client):
    """Phase 3: the ▶ Preview button + iframe modal + Alpine methods are wired."""
    r = client.get("/dev")
    assert r.status_code == 200
    # The Alpine methods that drive the ephemeral change preview.
    assert "startPreview" in r.text
    assert "closePreview" in r.text
    # The button only shows for external/ambiguous candidates.
    assert "preview_kind" in r.text
    # Neutral Spanish copy (no voseo).
    assert "Vista previa" in r.text
    assert "Levantando vista previa" in r.text
    assert "Cerrar" in r.text
    # Host rewrite for LAN access (not the literal 127.0.0.1 from the URL).
    assert "window.location.hostname" in r.text


def test_preview_goal_endpoint_returns_goal(client, monkeypatch):
    from axi import self_improve as si
    from axi import dev_run

    goal = "Agregá un test faltante al parser de fechas en ingestion.py."
    monkeypatch.setattr(si, "build_prod_call_model", lambda config: (lambda s, u: goal))
    monkeypatch.setattr(si, "build_prod_run_git", lambda repo_path: _routed_git)
    # A preview must NEVER start a dev run.
    monkeypatch.setattr(
        dev_run, "start_dev_run",
        lambda *a, **k: pytest.fail("preview endpoint must not start a dev run"),
    )

    r = client.post("/api/dev-runs/preview-goal")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["goal"] == goal
    assert body["source"] == "self_generated"
    assert body["signals"]["commits"] >= 1
    assert body["signals"]["changed_files"] >= 1


def test_preview_goal_endpoint_reports_model_failure(client, monkeypatch):
    from axi import self_improve as si

    def boom(config):
        raise RuntimeError("director unavailable")

    monkeypatch.setattr(si, "build_prod_call_model", boom)
    r = client.post("/api/dev-runs/preview-goal")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert "error" in body


# ===========================================================================
# Phase 3: ephemeral preview start/stop endpoints. dev_preview.preview_run /
# stop_preview are mocked — a preview must NEVER start a real instance here.
# ===========================================================================

_VALID_ID = "20260627-143000-a1b2c3"


def test_preview_start_returns_url(client, monkeypatch):
    from axi import dev_preview

    monkeypatch.setattr(
        dev_preview, "preview_run",
        lambda rid: {"ok": True, "url": "https://127.0.0.1:9100", "port": 9100, "run_id": rid},
    )
    r = client.post(f"/api/dev-runs/{_VALID_ID}/preview/start")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["url"] == "https://127.0.0.1:9100"
    assert body["port"] == 9100


def test_preview_start_invalid_run_id_400_without_calling_preview_run(client, monkeypatch):
    from axi import dev_preview

    monkeypatch.setattr(
        dev_preview, "preview_run",
        lambda rid: pytest.fail("preview_run must not be called for an invalid run_id"),
    )
    # A run_id that routes as one path segment but does not match the server shape.
    r = client.post("/api/dev-runs/x;rm/preview/start")
    assert r.status_code == 400


def test_preview_start_returns_400_on_not_ok(client, monkeypatch):
    from axi import dev_preview

    monkeypatch.setattr(
        dev_preview, "preview_run",
        lambda rid: {"ok": False, "error": "no patch for run"},
    )
    r = client.post(f"/api/dev-runs/{_VALID_ID}/preview/start")
    assert r.status_code == 400


def test_preview_stop_returns_ok(client, monkeypatch):
    from axi import dev_preview

    monkeypatch.setattr(dev_preview, "stop_preview", lambda rid: {"ok": True})
    r = client.post(f"/api/dev-runs/{_VALID_ID}/preview/stop")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_preview_stop_invalid_run_id_400_without_calling_stop(client, monkeypatch):
    from axi import dev_preview

    monkeypatch.setattr(
        dev_preview, "stop_preview",
        lambda rid: pytest.fail("stop_preview must not be called for an invalid run_id"),
    )
    r = client.post("/api/dev-runs/x;rm/preview/stop")
    assert r.status_code == 400


# --- list endpoint exposes preview_kind for reviewable candidates ------------


def _external_patch() -> str:
    return (
        "diff --git a/axi/src/axi/templates/dev_runs.html "
        "b/axi/src/axi/templates/dev_runs.html\n"
        "--- a/axi/src/axi/templates/dev_runs.html\n"
        "+++ b/axi/src/axi/templates/dev_runs.html\n"
        "@@ -1 +1 @@\n+<div>x</div>\n"
    )


def test_list_dev_runs_classifies_only_candidates(client, monkeypatch, tmp_path):
    from axi import dev_run, config

    results = tmp_path / "dev-results"
    results.mkdir()
    done_id = "20260627-143000-aaaaaa"
    running_id = "20260627-150000-bbbbbb"
    (results / f"{done_id}-1.patch").write_text(_external_patch())
    # The running run also gets a patch on disk to prove it is NOT read/classified.
    (results / f"{running_id}-1.patch").write_text(_external_patch())

    monkeypatch.setattr(dev_run, "list_runs", lambda: [
        {"run_id": done_id, "goal": "g", "status": "done"},
        {"run_id": running_id, "goal": "g2", "status": "running"},
    ])
    _orig_get = config.get

    def fake_get(key, default=None):
        if key == "dev_director_results_dir":
            return str(results)
        return _orig_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)

    r = client.get("/api/dev-runs")
    assert r.status_code == 200
    by_id = {x["run_id"]: x for x in r.json()}
    # Done run is a reviewable candidate → classified.
    assert by_id[done_id]["preview_kind"] == "external"
    # Running run is not a candidate → not classified (patch never read).
    assert by_id[running_id].get("preview_kind") is None


def test_list_dev_runs_candidate_without_patch_has_none_kind(client, monkeypatch, tmp_path):
    from axi import dev_run, config

    results = tmp_path / "dev-results"
    results.mkdir()
    done_id = "20260627-143000-cccccc"  # no patch written

    monkeypatch.setattr(dev_run, "list_runs", lambda: [
        {"run_id": done_id, "goal": "g", "status": "done"},
    ])
    _orig_get = config.get

    def fake_get(key, default=None):
        if key == "dev_director_results_dir":
            return str(results)
        return _orig_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)

    r = client.get("/api/dev-runs")
    by_id = {x["run_id"]: x for x in r.json()}
    assert by_id[done_id]["preview_kind"] is None
