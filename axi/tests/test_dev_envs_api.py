"""API + page tests for the Desarrollo section (dev environments).

dev_env / dev_env_instance are monkeypatched so no real state dir, worktree, or
systemd unit is touched.
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


def test_desarrollo_page_renders(client):
    r = client.get("/desarrollo")
    assert r.status_code == 200
    assert "devEnvs" in r.text          # the Alpine component is present
    assert "/static/recorder.js" in r.text  # shared voice recorder is loaded


def test_list_dev_envs_shapes_cards(client, monkeypatch):
    from axi import dev_env
    monkeypatch.setattr(dev_env, "list_envs", lambda: [
        {
            "run_id": "E1", "kind": "env", "title": "Kanban Salud",
            "description": "Tablero por estado", "goal": "agregá kanban",
            "status": "ready", "created_at": "2026-06-27T10:00:00+00:00",
            "rounds_done": 2, "branch": "axi/env/abc",
            "instance": {"status": "running", "url": "http://127.0.0.1:9003"},
        },
    ])
    r = client.get("/api/dev-envs")
    assert r.status_code == 200
    body = r.json()
    assert len(body) == 1
    card = body[0]
    assert card["env_id"] == "E1"
    assert card["title"] == "Kanban Salud"
    assert card["card_status"] == "ready"
    assert card["instance"]["url"] == "http://127.0.0.1:9003"


def test_create_dev_env(client, monkeypatch):
    from axi import dev_env
    seen = {}
    monkeypatch.setattr(dev_env, "create_env", lambda g: (seen.update({"goal": g}), "ENVNEW")[1])
    r = client.post("/api/dev-envs", json={"goal": "agregá export CSV"})
    assert r.status_code == 200
    assert r.json()["env_id"] == "ENVNEW"
    assert seen["goal"] == "agregá export CSV"


def test_create_dev_env_requires_goal(client):
    assert client.post("/api/dev-envs", json={"goal": "   "}).status_code == 400
    assert client.post("/api/dev-envs", json={}).status_code == 400


def test_get_dev_env_includes_diff(client, monkeypatch):
    from axi import dev_env, dev_env_instance, dashboard
    monkeypatch.setattr(dev_env_instance, "instance_status", lambda env_id: None)
    monkeypatch.setattr(dev_env, "get_env", lambda env_id: {
        "run_id": env_id, "kind": "env", "title": "T", "status": "ready",
        "worktree_path": "/nonexistent/wt", "branch": "axi/env/x",
    })
    # Diff helper returns "" for a non-existent worktree (no real git call).
    r = client.get("/api/dev-envs/E1")
    assert r.status_code == 200
    body = r.json()
    assert body["env_id"] == "E1"
    assert "diff" in body


def test_get_dev_env_404(client, monkeypatch):
    from axi import dev_env, dev_env_instance
    monkeypatch.setattr(dev_env_instance, "instance_status", lambda env_id: None)
    monkeypatch.setattr(dev_env, "get_env", lambda env_id: None)
    assert client.get("/api/dev-envs/nope").status_code == 404


def test_start_instance_endpoint_ok_and_error(client, monkeypatch):
    from axi import dev_env_instance
    monkeypatch.setattr(dev_env_instance, "start_instance",
                        lambda env_id: {"ok": True, "instance": {"url": "http://127.0.0.1:9005"}})
    r = client.post("/api/dev-envs/E1/instance/start")
    assert r.status_code == 200 and r.json()["instance"]["url"].endswith("9005")

    monkeypatch.setattr(dev_env_instance, "start_instance",
                        lambda env_id: {"ok": False, "error": "no worktree"})
    r2 = client.post("/api/dev-envs/E1/instance/start")
    assert r2.status_code == 400


def test_stop_instance_endpoint(client, monkeypatch):
    from axi import dev_env_instance
    called = {}
    monkeypatch.setattr(dev_env_instance, "stop_instance",
                        lambda env_id: (called.update({"id": env_id}), {"ok": True})[1])
    r = client.post("/api/dev-envs/E1/instance/stop")
    assert r.status_code == 200 and r.json()["ok"] is True
    assert called["id"] == "E1"


def test_iterate_env_endpoint(client, monkeypatch):
    from axi import dev_env
    seen = {}
    monkeypatch.setattr(dev_env, "iterate_env",
                        lambda eid, p: (seen.update({"id": eid, "p": p}), {"ok": True})[1])
    r = client.post("/api/dev-envs/E1/iterate", json={"prompt": "agrandá el botón"})
    assert r.status_code == 200 and r.json()["ok"] is True
    assert seen == {"id": "E1", "p": "agrandá el botón"}

    assert client.post("/api/dev-envs/E1/iterate", json={"prompt": "  "}).status_code == 400

    monkeypatch.setattr(dev_env, "iterate_env", lambda eid, p: {"ok": False, "error": "no worktree"})
    assert client.post("/api/dev-envs/E1/iterate", json={"prompt": "x"}).status_code == 400


def test_deploy_env_endpoint(client, monkeypatch):
    from axi import dev_env
    monkeypatch.setattr(dev_env, "deploy_env",
                        lambda env_id: {"ok": True, "pushed": True, "target": "main",
                                        "restart_hint": "git pull && restart"})
    r = client.post("/api/dev-envs/E1/deploy")
    assert r.status_code == 200
    body = r.json()
    assert body["pushed"] is True and body["target"] == "main"

    monkeypatch.setattr(dev_env, "deploy_env",
                        lambda env_id: {"ok": False, "error": "patch did not apply"})
    assert client.post("/api/dev-envs/E1/deploy").status_code == 400


def test_reject_env_endpoint(client, monkeypatch):
    from axi import dev_env
    monkeypatch.setattr(dev_env, "reject_env", lambda env_id: {"ok": True})
    r = client.post("/api/dev-envs/E1/reject")
    assert r.status_code == 200 and r.json()["ok"] is True

    monkeypatch.setattr(dev_env, "reject_env", lambda env_id: {"ok": False, "error": "boom"})
    assert client.post("/api/dev-envs/E1/reject").status_code == 400
