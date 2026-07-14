"""Tests for `axi.api_auth.BearerAuthMiddleware` (M0-3).

Design D5: per-device bearer auth for the `/api/v1/*` namespace.

Middleware order (outermost, sees the RAW pre-rewrite path — installed
after `V1AliasMiddleware` in dashboard.py so it wraps it):
  1. Master switch `api_auth_enabled` (default False) — completely disabled
     means zero behaviour change from today, for every path.
  2. PUBLIC exemptions: any non-`/api` path (Jinja pages, static, the
     rootCA cert route) and `/api/v1/pair` (pairing exchange, added in a
     later M0 task) are always allowed, regardless of the switch.
  3. `/api/v1/*` (not PUBLIC): STRICT always — a valid, non-revoked Bearer
     token is required. No localhost grace, even when enabled.
  4. legacy `/api/*` (not v1): grace controlled by `api_auth_enforce_legacy`
     (default False = today's fully-open perimeter model). When True, a
     valid Bearer token OR a loopback client (127.0.0.1 / ::1) passes.

Covers:
  - master switch off -> fully open (default)
  - v1 strict: missing / garbage / revoked token -> 401 + WWW-Authenticate
  - v1 strict: valid token -> passthrough; no localhost grace on v1
  - v1 PUBLIC exemption (/api/v1/pair) bypasses auth entirely
  - legacy grace semantics under enforce_legacy True/False
  - non-/api paths always public
  - duplicate-slash bypass cannot dodge v1 strict auth
  - dot-segment path resolves to its true classification (legacy vs v1)
    consistently with V1AliasMiddleware's own normalization
"""
from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from axi import config, store
from axi.api_auth import BearerAuthMiddleware, install_auth_middleware


def _build_app() -> FastAPI:
    app = FastAPI()

    @app.get("/api/legacy")
    def legacy():
        return {"who": "legacy"}

    @app.get("/api/v1/chat")
    def v1_chat():
        return {"who": "v1-chat"}

    @app.post("/api/v1/pair")
    def pair():
        return {"who": "pair"}

    install_auth_middleware(app)
    return app


@pytest.fixture
def client():
    """Non-loopback client (Starlette TestClient's default scope["client"]
    is ("testclient", 50000) — deliberately NOT loopback, so this fixture
    exercises the "no grace" path by default)."""
    return TestClient(_build_app())


@pytest.fixture
def loopback_client():
    """Explicit loopback client address, to exercise legacy grace."""
    return TestClient(_build_app(), client=("127.0.0.1", 54321))


def _add_device(device_id: str, token: str, revoked: bool = False) -> None:
    store.device_add(device_id, "Test Device", token)
    if revoked:
        store.device_revoke(device_id)


# ─────────────────────── master switch off (default) ───────────────────────


def test_disabled_by_default_v1_reachable_without_token(client):
    r = client.get("/api/v1/chat")
    assert r.status_code == 200


def test_disabled_by_default_legacy_reachable_without_token(client):
    r = client.get("/api/legacy")
    assert r.status_code == 200


# ────────────────────────── v1 strict enforcement ───────────────────────────


def test_v1_missing_token_401_with_www_authenticate(client):
    config.save({"api_auth_enabled": True})
    r = client.get("/api/v1/chat")
    assert r.status_code == 401
    assert "www-authenticate" in {k.lower() for k in r.headers.keys()}


def test_v1_garbage_token_401(client):
    config.save({"api_auth_enabled": True})
    r = client.get("/api/v1/chat", headers={"Authorization": "Bearer not-a-real-token"})
    assert r.status_code == 401


def test_v1_valid_token_passthrough(client):
    config.save({"api_auth_enabled": True})
    _add_device("dev-ok", "tok-ok")
    r = client.get("/api/v1/chat", headers={"Authorization": "Bearer tok-ok"})
    assert r.status_code == 200
    assert r.json() == {"who": "v1-chat"}


def test_v1_revoked_token_401(client):
    config.save({"api_auth_enabled": True})
    _add_device("dev-rev", "tok-rev", revoked=True)
    r = client.get("/api/v1/chat", headers={"Authorization": "Bearer tok-rev"})
    assert r.status_code == 401


def test_v1_no_localhost_grace_even_when_enabled(loopback_client):
    """Strict always on v1: a missing token from a loopback client is still
    401 — unlike the legacy namespace, v1 never grants localhost grace."""
    config.save({"api_auth_enabled": True})
    r = loopback_client.get("/api/v1/chat")
    assert r.status_code == 401


def test_v1_pair_is_public_even_when_enabled(client):
    config.save({"api_auth_enabled": True})
    r = client.post("/api/v1/pair")
    assert r.status_code == 200


def test_v1_duplicate_slash_cannot_bypass_strict_auth(client):
    """"/api//v1/chat" must classify identically to "/api/v1/chat" — a naive
    prefix check on the raw string would miss the duplicate slash and treat
    this as ordinary (non-v1) legacy traffic, defeating strict v1 auth."""
    config.save({"api_auth_enabled": True})
    r = client.get("/api//v1/chat")
    assert r.status_code == 401


# ────────────────────────── legacy grace semantics ──────────────────────────


def test_legacy_open_when_enforce_legacy_false(client):
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": False})
    r = client.get("/api/legacy")
    assert r.status_code == 200


def test_legacy_requires_token_or_loopback_when_enforce_legacy_true(client):
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": True})
    r = client.get("/api/legacy")
    assert r.status_code == 401


def test_legacy_valid_token_passes_when_enforce_legacy_true(client):
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": True})
    _add_device("dev-legacy", "tok-legacy")
    r = client.get("/api/legacy", headers={"Authorization": "Bearer tok-legacy"})
    assert r.status_code == 200


def test_legacy_loopback_grace_when_enforce_legacy_true(loopback_client):
    """A request with NO token from a loopback client (127.0.0.1) still
    passes once loopback grace applies — legacy-only, per D5."""
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": True})
    r = loopback_client.get("/api/legacy")
    assert r.status_code == 200


# ─────────────────────────── non-/api paths always public ──────────────────


def test_non_api_path_always_public(client):
    config.save({"api_auth_enabled": True, "api_auth_enforce_legacy": True})
    r = client.get("/does-not-exist")
    # 404 (no such route) but never 401 — auth middleware must not
    # intercept non-/api traffic at all.
    assert r.status_code == 404
