"""HTTP-level tests for /api/finance/entries endpoints.

Covers the edit path end-to-end:
  POST   /api/finance/entries          (helper — create fixtures)
  GET    /api/finance/entries          (list, to assert edits land)
  DELETE /api/finance/entries/{eid}    (soft delete, for the 404-on-deleted case)
  PATCH  /api/finance/entries/{eid}    (edit: success + 404 + 400)

The lifeos finance DB is isolated per-test via env var monkeypatching,
mirroring test_health_api.py's `health_isolated_db` fixture. We use
`kind="expense"` throughout so the big-purchase reflection scheduler never
fires during these tests.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient


# ── fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def finance_isolated_db(tmp_path, monkeypatch):
    """Redirect the finance encrypted DB to a throw-away temp file."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance-test.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance-test.key"))
    from lifeos.finance import store as finance_store
    finance_store.apply_migrations()
    yield


@pytest.fixture
def client(monkeypatch, finance_isolated_db):
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


def _create(client, *, kind="expense", title="café", amount=50, ts=None, **extra):
    payload = {"kind": kind, "title": title, "amount": amount,
               "ts": ts or _now_iso(), **extra}
    r = client.post("/api/finance/entries", json=payload)
    assert r.status_code == 200, r.text
    return r.json()


# ── PATCH /api/finance/entries/{eid} ─────────────────────────────────────────


def test_patch_edits_fields(client):
    entry = _create(client, kind="expense", title="original", amount=100,
                    category="food", merchant="Soriana")
    eid = entry["id"]

    patch_payload = {
        "kind": "expense",
        "title": "updated",
        "amount": 250.5,
        "ts": _now_iso(),
        "currency": "USD",
        "category": "electronics",
        "merchant": "Best Buy",
        "body": "new body",
        "tags": ["x", "y"],
    }
    r = client.patch(f"/api/finance/entries/{eid}", json=patch_payload)
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["title"] == "updated"
    assert data["amount"] == 250.5
    assert data["currency"] == "USD"
    assert data["category"] == "electronics"
    assert data["merchant"] == "Best Buy"
    assert data["body"] == "new body"
    assert data["tags"] == ["x", "y"]


def test_patch_reflected_in_list(client):
    entry = _create(client, title="before", amount=10)
    eid = entry["id"]

    client.patch(f"/api/finance/entries/{eid}", json={
        "kind": "expense", "title": "after", "amount": 10, "ts": _now_iso(),
    })

    r = client.get("/api/finance/entries")
    titles = [e["title"] for e in r.json()["entries"]]
    assert "after" in titles
    assert "before" not in titles


def test_patch_not_found_returns_404(client):
    r = client.patch("/api/finance/entries/nonexistent-id", json={
        "kind": "expense", "title": "x", "amount": 1, "ts": _now_iso(),
    })
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()


def test_patch_deleted_entry_returns_404(client):
    entry = _create(client, title="x", amount=1)
    eid = entry["id"]
    client.delete(f"/api/finance/entries/{eid}")

    r = client.patch(f"/api/finance/entries/{eid}", json={
        "kind": "expense", "title": "y", "amount": 1, "ts": _now_iso(),
    })
    assert r.status_code == 404


def test_patch_bad_kind_returns_400(client):
    entry = _create(client, title="x", amount=1)
    eid = entry["id"]
    r = client.patch(f"/api/finance/entries/{eid}", json={
        "kind": "banana", "title": "x", "amount": 1, "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_patch_negative_amount_returns_400(client):
    entry = _create(client, title="x", amount=1)
    eid = entry["id"]
    r = client.patch(f"/api/finance/entries/{eid}", json={
        "kind": "expense", "title": "x", "amount": -5, "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_patch_naive_ts_returns_400(client):
    entry = _create(client, title="x", amount=1)
    eid = entry["id"]
    r = client.patch(f"/api/finance/entries/{eid}", json={
        "kind": "expense", "title": "x", "amount": 1,
        "ts": "2026-06-01T09:00:00",  # no TZ
    })
    assert r.status_code == 400


def test_patch_missing_required_fields_returns_400(client):
    entry = _create(client, title="x", amount=1)
    eid = entry["id"]
    # Missing title, amount and ts
    r = client.patch(f"/api/finance/entries/{eid}", json={"kind": "expense"})
    assert r.status_code == 400
