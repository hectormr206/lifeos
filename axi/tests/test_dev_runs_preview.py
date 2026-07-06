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
