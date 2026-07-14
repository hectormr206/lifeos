"""Tests for `GET /api/v1/capabilities` (M0-4) and its interaction with the
bearer-auth middleware (M0-3) + the V1 alias middleware (M0-1), against the
REAL dashboard.app.

Design D4: capability negotiation payload — per-capability integer `v`,
additive fields never bump `v`. Native route on the dedicated
`APIRouter(prefix="/api/v1")` (axi.api_v1.router), so it always wins the
V1AliasMiddleware's Match.FULL probe and is never (and has no need to be)
aliased from a legacy twin.

Covers:
  - schema shape: api_version, engine_version, capabilities dict with
    integer "v" per capability
  - content reflects what exists TODAY (chat/organs/domains/graph/reminders)
  - native-v1 priority: /api/v1/capabilities is served directly; there is no
    legacy /api/capabilities twin (proves it wasn't reached via aliasing)
  - auth interplay: default (api_auth_enabled=False) -> reachable with no
    token; enabled -> requires a valid device bearer token like any other
    /api/v1/* route (capabilities is NOT in the PUBLIC exemption set)
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from axi import config, store


@pytest.fixture
def client():
    from axi import dashboard

    return TestClient(dashboard.app)


def test_capabilities_reachable_by_default_no_auth(client):
    r = client.get("/api/v1/capabilities")
    assert r.status_code == 200


def test_capabilities_schema_shape(client):
    body = client.get("/api/v1/capabilities").json()
    assert body["api_version"] == "1"
    assert isinstance(body["engine_version"], str) and body["engine_version"]
    caps = body["capabilities"]
    assert isinstance(caps, dict)
    for name in ("chat", "organs", "domains", "graph", "reminders"):
        assert name in caps, f"missing capability: {name}"
        assert isinstance(caps[name]["v"], int)


def test_capabilities_domains_list_reflects_existing_domains(client):
    body = client.get("/api/v1/capabilities").json()
    domains = body["capabilities"]["domains"]["list"]
    for expected in ("health", "finance", "relationships", "exercise"):
        assert expected in domains


def test_capabilities_organs_list_nonempty(client):
    body = client.get("/api/v1/capabilities").json()
    organs = body["capabilities"]["organs"]["list"]
    assert isinstance(organs, list)
    assert len(organs) > 0


def test_capabilities_chat_features_reflect_existing_endpoints(client):
    body = client.get("/api/v1/capabilities").json()
    features = body["capabilities"]["chat"]["features"]
    for expected in ("attachments", "tts", "transcribe"):
        assert expected in features


# ─────────────────────────── native-v1 priority ─────────────────────────────


def test_capabilities_has_no_legacy_twin(client):
    """There is no /api/capabilities Jinja/legacy route — proves the v1
    response is served by the native router, never by alias fallthrough."""
    r = client.get("/api/capabilities")
    assert r.status_code == 404


def test_capabilities_never_aliased_from_legacy(client):
    """Even though V1AliasMiddleware runs, /api/v1/capabilities must be
    classified as a native-v1 Match.FULL hit and served directly."""
    r = client.get("/api/v1/capabilities")
    assert r.status_code == 200
    assert "capabilities" in r.json()


# ────────────────────────────── auth interplay ──────────────────────────────


def test_capabilities_requires_token_when_auth_enabled(client):
    config.save({"api_auth_enabled": True})
    r = client.get("/api/v1/capabilities")
    assert r.status_code == 401


def test_capabilities_accessible_with_valid_device_token(client):
    config.save({"api_auth_enabled": True})
    store.device_add("dev-caps", "Caps Tester", "tok-caps")
    r = client.get(
        "/api/v1/capabilities", headers={"Authorization": "Bearer tok-caps"}
    )
    assert r.status_code == 200
    assert r.json()["api_version"] == "1"
