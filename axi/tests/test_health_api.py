"""HTTP-level tests for /api/health/entries endpoints.

Covers:
  GET /api/health/entries (list, kind filter, days filter, q search)
  POST /api/health/entries (success + validation failures)
  DELETE /api/health/entries/{eid} (soft delete)
  PATCH /api/health/entries/{eid} (edit: success + 404 + 400)

The lifeos health DB is isolated per-test via env var monkeypatching,
mirroring the pattern in test_reminders_e2e.py's `lifeos_isolated_db` fixture.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient


# ── fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def health_isolated_db(tmp_path, monkeypatch):
    """Redirect the health encrypted DB to a throw-away temp file."""
    db_path = tmp_path / "health-test.db"
    key_path = tmp_path / "health-test.key"
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(key_path))
    from lifeos.health import store as health_store
    health_store.apply_migrations()
    yield


@pytest.fixture
def client(monkeypatch, health_isolated_db):
    from axi import dashboard
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


# ── helpers ───────────────────────────────────────────────────────────────────


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _create(client, *, kind="note", title="test entry", ts=None, **extra):
    payload = {"kind": kind, "title": title, "ts": ts or _now_iso(), **extra}
    r = client.post("/api/health/entries", json=payload)
    assert r.status_code == 200, r.text
    return r.json()


# ── GET /api/health/entries ───────────────────────────────────────────────────


def test_list_empty(client):
    r = client.get("/api/health/entries")
    assert r.status_code == 200
    assert r.json() == {"entries": []}


def test_list_returns_created_entry(client):
    _create(client, title="headache", kind="symptom")
    r = client.get("/api/health/entries")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["title"] == "headache"
    assert entries[0]["kind"] == "symptom"


def test_list_kind_filter(client):
    _create(client, kind="symptom", title="dolor")
    _create(client, kind="note", title="nota")
    r = client.get("/api/health/entries?kind=symptom")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["kind"] == "symptom"


def test_list_days_filter_excludes_old(client):
    old_ts = (datetime.now(timezone.utc) - timedelta(days=100)).isoformat()
    recent_ts = datetime.now(timezone.utc).isoformat()
    _create(client, title="old entry", ts=old_ts)
    _create(client, title="recent entry", ts=recent_ts)
    r = client.get("/api/health/entries?days=30")
    assert r.status_code == 200
    titles = [e["title"] for e in r.json()["entries"]]
    assert "recent entry" in titles
    assert "old entry" not in titles


def test_list_q_search(client):
    _create(client, title="dolor de garganta", kind="symptom")
    _create(client, title="nota diaria", kind="note")
    r = client.get("/api/health/entries?q=garganta")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["title"] == "dolor de garganta"


# ── POST /api/health/entries ──────────────────────────────────────────────────


def test_create_success(client):
    payload = {
        "kind": "symptom",
        "title": "headache",
        "ts": _now_iso(),
        "body": "mild",
        "tags": ["morning"],
        "source": "manual",
    }
    r = client.post("/api/health/entries", json=payload)
    assert r.status_code == 200
    data = r.json()
    assert data["id"]
    assert data["title"] == "headache"
    assert data["kind"] == "symptom"
    assert data["tags"] == ["morning"]
    assert data["source"] == "manual"


def test_create_bad_kind_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "banana", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_create_missing_title_returns_400(client):
    r = client.post("/api/health/entries", json={"kind": "note", "ts": _now_iso()})
    assert r.status_code == 400


def test_create_missing_ts_returns_400(client):
    r = client.post("/api/health/entries", json={"kind": "note", "title": "x"})
    assert r.status_code == 400


def test_create_bad_ts_format_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": "not-a-date",
    })
    assert r.status_code == 400


def test_create_naive_ts_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": "2026-06-01T09:00:00",  # no TZ
    })
    assert r.status_code == 400


def test_create_title_too_long_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x" * 201, "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_create_bad_source_enum_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": _now_iso(), "source": "robot",
    })
    assert r.status_code == 400


# ── DELETE /api/health/entries/{eid} ─────────────────────────────────────────


def test_delete_soft_deletes(client):
    entry = _create(client, title="to-delete")
    eid = entry["id"]

    r = client.delete(f"/api/health/entries/{eid}")
    assert r.status_code == 200
    assert r.json()["deleted"] is True

    # No longer appears in list
    r = client.get("/api/health/entries")
    ids = [e["id"] for e in r.json()["entries"]]
    assert eid not in ids


def test_delete_nonexistent_returns_deleted_false(client):
    r = client.delete("/api/health/entries/nonexistent-id")
    assert r.status_code == 200
    assert r.json()["deleted"] is False


# ── PATCH /api/health/entries/{eid} ──────────────────────────────────────────


def test_patch_edits_fields(client):
    entry = _create(client, kind="note", title="original", ts=_now_iso())
    eid = entry["id"]

    new_ts = datetime.now(timezone.utc).isoformat()
    patch_payload = {
        "kind": "symptom",
        "title": "updated",
        "ts": new_ts,
        "body": "new body",
        "tags": ["x", "y"],
    }
    r = client.patch(f"/api/health/entries/{eid}", json=patch_payload)
    assert r.status_code == 200
    data = r.json()
    assert data["title"] == "updated"
    assert data["kind"] == "symptom"
    assert data["body"] == "new body"
    assert data["tags"] == ["x", "y"]


def test_patch_reflected_in_list(client):
    entry = _create(client, title="before")
    eid = entry["id"]

    client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "after", "ts": _now_iso(),
    })

    r = client.get("/api/health/entries")
    titles = [e["title"] for e in r.json()["entries"]]
    assert "after" in titles
    assert "before" not in titles


def test_patch_not_found_returns_404(client):
    r = client.patch("/api/health/entries/nonexistent-id", json={
        "kind": "note", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()


def test_patch_deleted_entry_returns_404(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    client.delete(f"/api/health/entries/{eid}")

    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "y", "ts": _now_iso(),
    })
    assert r.status_code == 404


def test_patch_bad_kind_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "banana", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_patch_naive_ts_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "x", "ts": "2026-06-01T09:00:00",  # no TZ
    })
    assert r.status_code == 400


def test_patch_missing_required_fields_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    # Missing title and ts
    r = client.patch(f"/api/health/entries/{eid}", json={"kind": "note"})
    assert r.status_code == 400
