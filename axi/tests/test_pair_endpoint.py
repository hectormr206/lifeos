"""Tests for QR pairing (M0-5, design D6 + spec `api-auth-pairing`):

  - `GET /api/setup/pairing_code` (legacy namespace, drives the `/setup` QR)
  - `POST /api/v1/pair` (native v1 route, PUBLIC even when auth is enabled)

Against the REAL `dashboard.app`, mirroring `test_capabilities.py` /
`test_api_auth_middleware.py` conventions.

Covers:
  - pairing_code endpoint schema (v, code, expires_at, urls, ca_fp)
  - ca_fp is the SHA-256 of the CA cert's DER bytes (None if CA missing)
  - successful pair: valid code -> device token issued, device_add called,
    device appears in store.device_list()
  - expired/invalid/already-used code rejected (410), no token issued
  - missing `code` field -> 422 (FastAPI/pydantic validation)
  - /api/v1/pair remains reachable with NO bearer token even when
    api_auth_enabled=true (PUBLIC_V1_PATHS, already wired in M0-3)
  - raw token is never persisted — only its SHA-256 hash
"""
from __future__ import annotations

import base64
import hashlib

import pytest
from fastapi.testclient import TestClient

from axi import config, pairing, store


@pytest.fixture
def client():
    from axi import dashboard

    return TestClient(dashboard.app)


@pytest.fixture(autouse=True)
def _reset_pairing_state():
    pairing._reset_for_tests()
    yield
    pairing._reset_for_tests()


def _mint_code(client) -> str:
    r = client.get("/api/setup/pairing_code")
    assert r.status_code == 200
    return r.json()["code"]


# ─────────────────────── GET /api/setup/pairing_code ────────────────────────


def test_pairing_code_schema_shape(client):
    r = client.get("/api/setup/pairing_code")
    assert r.status_code == 200
    body = r.json()
    assert body["v"] == 1
    assert isinstance(body["code"], str) and body["code"]
    assert isinstance(body["expires_at"], float)
    assert isinstance(body["urls"], list) and len(body["urls"]) >= 1
    assert "ca_fp" in body


def test_pairing_code_ca_fp_none_when_ca_missing(client, monkeypatch, tmp_path):
    from axi import dashboard

    monkeypatch.setattr(
        dashboard, "_mkcert_root_ca_path", lambda: tmp_path / "does-not-exist.pem"
    )
    r = client.get("/api/setup/pairing_code")
    assert r.json()["ca_fp"] is None


def test_pairing_code_ca_fp_is_sha256_of_der(client, monkeypatch, tmp_path):
    from axi import dashboard

    fake_der = b"fake-certificate-der-bytes-for-testing"
    fake_pem = (
        "-----BEGIN CERTIFICATE-----\n"
        + base64.b64encode(fake_der).decode()
        + "\n-----END CERTIFICATE-----\n"
    )
    ca_path = tmp_path / "rootCA.pem"
    ca_path.write_text(fake_pem)
    monkeypatch.setattr(dashboard, "_mkcert_root_ca_path", lambda: ca_path)

    r = client.get("/api/setup/pairing_code")
    assert r.json()["ca_fp"] == hashlib.sha256(fake_der).hexdigest()


def test_pairing_code_each_call_mints_a_new_code(client):
    a = client.get("/api/setup/pairing_code").json()["code"]
    b = client.get("/api/setup/pairing_code").json()["code"]
    assert a != b


# ─────────────────────────── POST /api/v1/pair ───────────────────────────────


def test_pair_success_issues_device_token(client):
    code = _mint_code(client)
    r = client.post(
        "/api/v1/pair",
        json={"code": code, "device_name": "Hector's Pixel"},
    )
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body["device_id"], str) and body["device_id"]
    assert isinstance(body["token"], str) and len(body["token"]) >= 20
    assert "capabilities" in body


def test_pair_registers_device_in_store(client):
    code = _mint_code(client)
    r = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Test Phone"}
    )
    body = r.json()
    devices = store.device_list()
    match = next(d for d in devices if d["device_id"] == body["device_id"])
    assert match["name"] == "Test Phone"
    assert match["revoked_at"] is None


def test_pair_raw_token_never_persisted(client):
    code = _mint_code(client)
    body = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Test Phone"}
    ).json()
    device = store.device_get_by_token_hash(store.hash_device_token(body["token"]))
    assert device is not None
    assert device["device_id"] == body["device_id"]
    # The device row (per _DEVICE_COLUMNS) never includes a raw token or
    # even the hash itself in caller-facing dicts.
    assert "token" not in device
    assert "token_hash" not in device


def test_pair_optional_device_pubkey_stored(client):
    code = _mint_code(client)
    body = client.post(
        "/api/v1/pair",
        json={"code": code, "device_name": "Pubkey Phone", "device_pubkey": "abc123"},
    ).json()
    match = next(
        d for d in store.device_list() if d["device_id"] == body["device_id"]
    )
    assert match["device_pubkey"] == "abc123"


def test_pair_invalid_code_rejected(client):
    r = client.post(
        "/api/v1/pair", json={"code": "not-a-real-code", "device_name": "X"}
    )
    assert r.status_code == 410
    assert store.device_list() == []


def test_pair_code_single_use_second_attempt_rejected(client):
    code = _mint_code(client)
    first = client.post("/api/v1/pair", json={"code": code, "device_name": "First"})
    assert first.status_code == 200
    second = client.post("/api/v1/pair", json={"code": code, "device_name": "Second"})
    assert second.status_code == 410


def test_pair_expired_code_rejected(client, monkeypatch):
    session = pairing.create_code()
    monkeypatch.setattr(pairing.time, "time", lambda: session["expires_at"] + 1)
    r = client.post(
        "/api/v1/pair", json={"code": session["code"], "device_name": "X"}
    )
    assert r.status_code == 410


def test_pair_missing_code_field_422(client):
    r = client.post("/api/v1/pair", json={"device_name": "X"})
    assert r.status_code == 422


# ──────────────────────── public even when auth enabled ─────────────────────


def test_pair_reachable_without_bearer_token_when_auth_enabled(client):
    config.save({"api_auth_enabled": True})
    code = _mint_code(client)
    r = client.post("/api/v1/pair", json={"code": code, "device_name": "X"})
    assert r.status_code == 200


def test_pairing_code_endpoint_reachable_without_bearer_when_auth_enabled(client):
    # /api/setup/pairing_code is a legacy (non-/api/v1) path -> gated only by
    # api_auth_enforce_legacy, which defaults False.
    config.save({"api_auth_enabled": True})
    r = client.get("/api/setup/pairing_code")
    assert r.status_code == 200
