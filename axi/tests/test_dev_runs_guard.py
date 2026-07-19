"""Guard-blocked auto-dev runs must read as a disabled 'Bloqueado' state.

A nightly self-improve run whose diff touches the protected dev-engine paths is
flagged with ``guard_blocked=True`` at land/ship time. The dashboard must:

  1. surface that flag (and its human reason) on the list + single-run APIs,
  2. render a disabled '🔒 Bloqueado' pill in the UI and suppress every
     approve/merge/deploy control for the run, and
  3. refuse the approve/merge/deploy endpoints server-side (defense in depth),
     so a stale client or a direct API call can never act on a blocked run.
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


_BLOCKED_RUN = {
    "run_id": "run-blocked-0001",
    "goal": "Refactor the nightly loop",
    "status": "needs_human",
    "started_at": "2026-07-19T00:00:00Z",
    "rounds_done": 2,
    "origin": "self_improve",
    "guard_blocked": True,
    "guard_offenders": ["axi/src/axi/dev_land.py"],
    "guard_reason": (
        "Bloqueado: un run de auto-mejora intentó modificar el motor de "
        "desarrollo (axi/src/axi/dev_land.py). No se hizo push."
    ),
}


# ── 1. API surfaces the flag ────────────────────────────────────────────────

def test_list_api_surfaces_guard_fields(client, monkeypatch):
    from axi import dev_run
    monkeypatch.setattr(dev_run, "list_runs", lambda: [dict(_BLOCKED_RUN)])

    r = client.get("/api/dev-runs")
    assert r.status_code == 200
    run = r.json()[0]
    assert run["guard_blocked"] is True
    assert "motor de desarrollo" in run["guard_reason"]


def test_list_api_guard_false_for_normal_run(client, monkeypatch):
    from axi import dev_run
    normal = {"run_id": "run-ok-1", "goal": "x", "status": "done", "rounds_done": 1}
    monkeypatch.setattr(dev_run, "list_runs", lambda: [normal])

    run = client.get("/api/dev-runs").json()[0]
    assert run["guard_blocked"] is False
    assert run["guard_reason"] == ""


def test_get_api_surfaces_guard_fields(client, monkeypatch):
    from axi import dev_run
    monkeypatch.setattr(dev_run, "get_run", lambda rid: dict(_BLOCKED_RUN))

    r = client.get("/api/dev-runs/run-blocked-0001")
    assert r.status_code == 200
    body = r.json()
    assert body["guard_blocked"] is True
    assert "motor de desarrollo" in body["guard_reason"]


# ── 2. UI gates the button ──────────────────────────────────────────────────

def test_page_renders_blocked_pill_and_gates_actions(client):
    r = client.get("/dev")
    assert r.status_code == 200
    # A disabled, non-clickable 'Bloqueado' badge that shows the reason.
    assert "Bloqueado" in r.text
    assert "guard_reason" in r.text
    # Action controls are gated on !guard_blocked so a blocked run never offers
    # a live approve/merge/deploy/ship button.
    assert "!r.guard_blocked" in r.text


# ── 3. Server-side refusal (defense in depth) ───────────────────────────────

@pytest.mark.parametrize("verb", ["approve", "merge", "deploy"])
def test_action_endpoints_refuse_blocked_run(client, monkeypatch, verb):
    from axi import dev_run, dev_land
    monkeypatch.setattr(dev_run, "get_run", lambda rid: dict(_BLOCKED_RUN))

    # None of the land/merge/deploy work may run for a blocked run.
    def _boom(*a, **k):
        pytest.fail("guard-blocked run must be refused before any land work")

    monkeypatch.setattr(dev_land, "land_run", _boom)
    monkeypatch.setattr(dev_land, "merge_run", _boom)
    monkeypatch.setattr(dev_land, "deploy_run", _boom)

    r = client.post(f"/api/dev-runs/run-blocked-0001/{verb}")
    assert r.status_code in (400, 409)
    assert "motor de desarrollo" in r.json()["detail"]
