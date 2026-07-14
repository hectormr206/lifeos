"""Tests for the device-revoke admin surface (M0-6): `GET /api/devices` +
`POST /api/devices/{device_id}/revoke`, backing the `/config` page's device
list + revoke button.

Design D5: "Revocation = set revoked_at (config page UI)." These are
LEGACY (non-`/api/v1`) routes — the config page is operated locally by the
owner in-browser, not by a paired mobile device, so they follow the same
perimeter model as the existing `/api/config` endpoints (gated only by
`api_auth_enforce_legacy`, default-open) rather than the strict-always
`/api/v1/*` bearer requirement meant for mobile clients.

Both `store.device_list()` and `store.device_revoke()` already existed
(batch 1) — this batch only wires HTTP routes + config-page UI on top.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from axi import config, store


@pytest.fixture
def client():
    from axi import dashboard

    return TestClient(dashboard.app)


def test_list_devices_empty_by_default(client):
    r = client.get("/api/devices")
    assert r.status_code == 200
    assert r.json() == {"devices": []}


def test_list_devices_after_add(client):
    store.device_add("dev-1", "Phone 1", "tok-1")
    r = client.get("/api/devices")
    assert r.status_code == 200
    devices = r.json()["devices"]
    assert len(devices) == 1
    assert devices[0]["device_id"] == "dev-1"
    assert devices[0]["name"] == "Phone 1"
    assert "token_hash" not in devices[0]
    assert "token" not in devices[0]


def test_revoke_active_device(client):
    store.device_add("dev-2", "Phone 2", "tok-2")
    r = client.post("/api/devices/dev-2/revoke")
    assert r.status_code == 200
    body = r.json()
    assert body == {"device_id": "dev-2", "revoked": True, "already_revoked": False}
    match = next(d for d in store.device_list() if d["device_id"] == "dev-2")
    assert match["revoked_at"] is not None


def test_revoke_unknown_device_404(client):
    r = client.post("/api/devices/no-such-device/revoke")
    assert r.status_code == 404


def test_revoke_twice_is_idempotent(client):
    store.device_add("dev-3", "Phone 3", "tok-3")
    first = client.post("/api/devices/dev-3/revoke")
    second = client.post("/api/devices/dev-3/revoke")
    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["already_revoked"] is True


def test_revoked_device_fails_auth(client):
    """End-to-end sanity: a device revoked through this admin endpoint is
    rejected by BearerAuthMiddleware on its next v1 request (M0-3)."""
    store.device_add("dev-4", "Phone 4", "tok-4")
    config.save({"api_auth_enabled": True})
    ok = client.get(
        "/api/v1/capabilities", headers={"Authorization": "Bearer tok-4"}
    )
    assert ok.status_code == 200
    client.post("/api/devices/dev-4/revoke")
    rejected = client.get(
        "/api/v1/capabilities", headers={"Authorization": "Bearer tok-4"}
    )
    assert rejected.status_code == 401


# ────────────────── legacy grace semantics (consistent w/ /api/config) ──────


def test_devices_endpoints_open_by_default_even_with_auth_enabled(client):
    config.save({"api_auth_enabled": True})
    r = client.get("/api/devices")
    assert r.status_code == 200


def test_devices_endpoints_require_token_or_loopback_when_enforce_legacy(client):
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": True})
    r = client.get("/api/devices")
    # TestClient's default scope["client"] is non-loopback ("testclient", ...),
    # so with no bearer token this must be rejected just like any other
    # legacy route under enforcement.
    assert r.status_code == 401
