"""End-to-end tests for the reminders API endpoints.

Full cycle: POST create → GET list → PATCH edit → GET reflects changes
            → PATCH on non-pending returns 404 → DELETE cancel.

The scheduler is stubbed so no APScheduler jobs are actually started.
The lifeos DB is redirected to a temp file via LIFEOS_DB_PATH (same pattern
as the lifeos unit tests' _isolated_db fixture).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient


class _FakeScheduler:
    """Minimal scheduler stub that captures calls without side-effects."""

    def __init__(self):
        self.scheduled: list = []
        self.cancelled: list = []

    def schedule(self, rem):
        self.scheduled.append(rem)

    def cancel(self, rid: str):
        self.cancelled.append(rid)


@pytest.fixture
def fake_scheduler(monkeypatch):
    """Patch get_scheduler to return a FakeScheduler instance."""
    from axi import dashboard
    sched = _FakeScheduler()
    monkeypatch.setattr(dashboard, "get_scheduler", lambda: sched)
    return sched


@pytest.fixture
def lifeos_isolated_db(tmp_path, monkeypatch):
    """Point lifeos store at a per-test temp DB and run its migrations."""
    db_path = tmp_path / "lifeos-test.db"
    key_path = tmp_path / "lifeos-test.key"
    monkeypatch.setenv("LIFEOS_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(key_path))
    # Force lifeos store to re-open against the temp DB by clearing its
    # module-level connection cache.
    from lifeos import store as lifeos_store
    # store uses a threading.local or module-level _conn; reset it.
    if hasattr(lifeos_store, "_conn"):
        try:
            if lifeos_store._conn is not None:
                lifeos_store._conn.close()
        except Exception:
            pass
        monkeypatch.setattr(lifeos_store, "_conn", None)
    lifeos_store.apply_migrations()
    yield


@pytest.fixture
def client(monkeypatch, lifeos_isolated_db, fake_scheduler):
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


# ── helpers ──────────────────────────────────────────────────────────────────

def _future_iso(hours: int = 2) -> str:
    dt = datetime.now(timezone.utc) + timedelta(hours=hours)
    return dt.isoformat()


# ── tests ─────────────────────────────────────────────────────────────────────

def test_reminders_page_renders(client):
    r = client.get("/reminders")
    assert r.status_code == 200
    assert "Recordatorios" in r.text


def test_create_then_list(client, fake_scheduler):
    payload = {"when": _future_iso(2), "message": "llamar dentista", "channel": "log"}
    r = client.post("/api/reminders", json=payload)
    assert r.status_code == 200
    data = r.json()
    assert data["message"] == "llamar dentista"
    assert data["status"] == "pending"
    rid = data["id"]

    # Scheduler should have been called
    assert len(fake_scheduler.scheduled) == 1
    assert fake_scheduler.scheduled[0].id == rid

    # GET list shows it
    r = client.get("/api/reminders?status=pending")
    assert r.status_code == 200
    ids = [x["id"] for x in r.json()["reminders"]]
    assert rid in ids


def test_patch_edits_all_fields(client, fake_scheduler):
    # Create
    payload = {
        "when": _future_iso(2),
        "message": "original",
        "channel": "log",
        "recurrence": "0 9 * * *",
    }
    r = client.post("/api/reminders", json=payload)
    assert r.status_code == 200
    rid = r.json()["id"]
    assert len(fake_scheduler.scheduled) == 1

    # PATCH
    new_when = _future_iso(5)
    patch_payload = {
        "when": new_when,
        "message": "updated",
        "channel": "push",
        "recurrence": "0 21 * * *",
        "occurrences_left": 5,
    }
    r = client.patch(f"/api/reminders/{rid}", json=patch_payload)
    assert r.status_code == 200
    data = r.json()
    assert data["message"] == "updated"
    assert data["channel"] == "push"
    assert data["recurrence"] == "0 21 * * *"
    assert data["occurrences_left"] == 5
    assert data["status"] == "pending"

    # Scheduler: cancel old job, schedule new one
    assert rid in fake_scheduler.cancelled
    # Two schedule calls: original create + patch reschedule
    assert len(fake_scheduler.scheduled) == 2
    assert fake_scheduler.scheduled[1].id == rid

    # GET reflects changes
    r = client.get("/api/reminders?status=pending")
    items = {x["id"]: x for x in r.json()["reminders"]}
    assert items[rid]["message"] == "updated"
    assert items[rid]["recurrence"] == "0 21 * * *"


def test_patch_not_found_returns_404(client):
    r = client.patch("/api/reminders/nonexistent-id", json={
        "when": _future_iso(2), "message": "x", "channel": "log",
    })
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()


def test_patch_on_cancelled_returns_404(client, fake_scheduler):
    r = client.post("/api/reminders", json={
        "when": _future_iso(2), "message": "x", "channel": "log",
    })
    rid = r.json()["id"]

    # Cancel it first
    r = client.delete(f"/api/reminders/{rid}")
    assert r.json()["cancelled"] is True

    # Attempt PATCH → 404
    r = client.patch(f"/api/reminders/{rid}", json={
        "when": _future_iso(3), "message": "updated", "channel": "log",
    })
    assert r.status_code == 404


def test_patch_invalid_cron_returns_400(client, fake_scheduler):
    r = client.post("/api/reminders", json={
        "when": _future_iso(2), "message": "x", "channel": "log",
    })
    rid = r.json()["id"]

    r = client.patch(f"/api/reminders/{rid}", json={
        "when": _future_iso(3),
        "message": "x",
        "channel": "log",
        "recurrence": "not a valid cron",
    })
    assert r.status_code == 400


def test_patch_naive_when_returns_400(client, fake_scheduler):
    r = client.post("/api/reminders", json={
        "when": _future_iso(2), "message": "x", "channel": "log",
    })
    rid = r.json()["id"]

    r = client.patch(f"/api/reminders/{rid}", json={
        "when": "2026-06-01T09:00:00",  # no TZ
        "message": "x",
        "channel": "log",
    })
    assert r.status_code == 400


def test_full_cycle_create_patch_delete(client, fake_scheduler):
    # Create
    r = client.post("/api/reminders", json={
        "when": _future_iso(1), "message": "step1", "channel": "log",
    })
    assert r.status_code == 200
    rid = r.json()["id"]

    # Edit
    r = client.patch(f"/api/reminders/{rid}", json={
        "when": _future_iso(3), "message": "step2", "channel": "push",
    })
    assert r.status_code == 200
    assert r.json()["message"] == "step2"

    # Delete
    r = client.delete(f"/api/reminders/{rid}")
    assert r.json()["cancelled"] is True

    # Pending list no longer contains it
    r = client.get("/api/reminders?status=pending")
    ids = [x["id"] for x in r.json()["reminders"]]
    assert rid not in ids
