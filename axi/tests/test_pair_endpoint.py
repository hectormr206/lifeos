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


def _pop_fields(code: str, device_priv: str, device_pub: str) -> dict:
    """Build the on-the-wire PoP fields for `device_pubkey`: sign
    `{"code", "device_pubkey"}` with the DEVICE's own key (reuses
    `build_signed_payload`/`sign_request`, spec `mesh-trust-hardening`)."""
    from axi import mesh_trust

    payload = mesh_trust.build_signed_payload({"code": code, "device_pubkey": device_pub})
    sig = mesh_trust.sign_request(device_priv, payload)
    return {
        "device_pubkey": device_pub,
        "pubkey_proof": sig,
        "pubkey_proof_payload": base64.b64encode(payload).decode("ascii"),
    }


def test_pair_device_pubkey_without_pop_is_refused(client):
    """Scenario: pairing with an unproven device_pubkey is refused."""
    code = _mint_code(client)
    r = client.post(
        "/api/v1/pair",
        json={"code": code, "device_name": "No Proof", "device_pubkey": "abc123"},
    )
    assert r.status_code == 400
    assert "proof" in r.json()["detail"].lower()
    assert store.device_list() == []


def test_pair_device_pubkey_with_valid_pop_succeeds(client):
    """Scenario: pairing with a valid PoP succeeds (as today) and the key is
    recorded proven."""
    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    r = client.post(
        "/api/v1/pair",
        json={
            "code": code,
            "device_name": "Proven Phone",
            **_pop_fields(code, device_priv, device_pub),
        },
    )
    assert r.status_code == 200
    body = r.json()
    match = next(
        d for d in store.device_list() if d["device_id"] == body["device_id"]
    )
    assert match["device_pubkey"] == device_pub
    assert match["pubkey_proven"] == 1


def test_pair_pop_signed_by_wrong_key_is_refused(client):
    """A proof signed by a DIFFERENT key than the claimed device_pubkey must
    fail — proving possession of SOME key is not proving possession of THIS
    key."""
    from axi import mesh_trust

    device_priv, _device_pub = mesh_trust.new_node_keypair()
    _other_priv, claimed_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    fields = _pop_fields(code, device_priv, claimed_pub)  # signed by the WRONG key
    r = client.post(
        "/api/v1/pair",
        json={"code": code, "device_name": "Mismatched", **fields},
    )
    assert r.status_code == 400
    assert store.device_list() == []


def test_pair_failed_pop_does_not_burn_the_pairing_code(client):
    """Anti-code-burning: a rejected PoP attempt must NOT consume the
    single-use pairing code — a retry with the SAME code and a VALID proof
    must still succeed. This is the exact situation a real user hits when
    their first attempt has a bug/mismatch: without this guarantee they'd be
    told to generate a brand new code for no reason, with no explanation."""
    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)

    # First attempt: INVALID proof (garbage signature) -> refused, code
    # must survive.
    bad = client.post(
        "/api/v1/pair",
        json={
            "code": code,
            "device_name": "Retry Phone",
            "device_pubkey": device_pub,
            "pubkey_proof": "00" * 64,  # well-formed hex, wrong signature
            "pubkey_proof_payload": _pop_fields(code, device_priv, device_pub)[
                "pubkey_proof_payload"
            ],
        },
    )
    assert bad.status_code == 400
    assert store.device_list() == []

    # Second attempt: SAME code, this time with a VALID proof -> succeeds.
    good = client.post(
        "/api/v1/pair",
        json={
            "code": code,
            "device_name": "Retry Phone",
            **_pop_fields(code, device_priv, device_pub),
        },
    )
    assert good.status_code == 200
    body = good.json()
    match = next(
        d for d in store.device_list() if d["device_id"] == body["device_id"]
    )
    assert match["device_pubkey"] == device_pub
    assert match["pubkey_proven"] == 1


def test_pair_no_device_pubkey_is_unaffected_legacy_path(client):
    """Scenario: pairing with no device_pubkey is unaffected (legacy path) —
    no proof required, pairing proceeds unchanged."""
    code = _mint_code(client)
    r = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Legacy Phone"}
    )
    assert r.status_code == 200
    body = r.json()
    match = next(
        d for d in store.device_list() if d["device_id"] == body["device_id"]
    )
    assert match["device_pubkey"] is None
    assert match["pubkey_proven"] == 0


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


# ─────────────────────────────────────────────────────────────────────────────
# Advertised URLs: a wildcard bind address is NOT a reachable URL
# ─────────────────────────────────────────────────────────────────────────────


def test_pairing_urls_never_advertise_wildcard_bind(monkeypatch):
    """dashboard_host=0.0.0.0 is a BIND address — a phone cannot connect to it.

    The pairing payload must advertise real, reachable addresses (e.g. the
    VPN/LAN interface IPs), never the wildcard.
    """
    from fastapi.testclient import TestClient
    import axi.dashboard as dashboard
    from axi import config

    real_get = config.get

    def fake_get(key, default=None):
        if key == "dashboard_host":
            return "0.0.0.0"
        return real_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)
    client = TestClient(dashboard.app)
    r = client.get("/api/setup/pairing_code")
    assert r.status_code == 200
    urls = r.json()["urls"]
    assert urls, "must advertise at least one URL"
    assert all("0.0.0.0" not in u for u in urls), f"wildcard leaked: {urls}"
    assert all(u.startswith("https://") for u in urls)


def test_pairing_urls_keep_concrete_host(monkeypatch):
    """A concrete configured host (e.g. 127.0.0.1) is advertised as-is."""
    from fastapi.testclient import TestClient
    import axi.dashboard as dashboard
    from axi import config

    real_get = config.get

    def fake_get(key, default=None):
        if key == "dashboard_host":
            return "127.0.0.1"
        return real_get(key, default)

    monkeypatch.setattr(config, "get", fake_get)
    client = TestClient(dashboard.app)
    r = client.get("/api/setup/pairing_code")
    assert r.status_code == 200
    assert any("127.0.0.1" in u for u in r.json()["urls"])


# ──────────────── PoP envelope freshness: `ts` and `nonce` ─────────────────
#
# `build_signed_payload` embeds a `ts` and a random `nonce` INSIDE the signed
# bytes specifically so a verifier can reject stale or replayed requests, and
# its docstring says enforcement is the caller's job. `_verify_pubkey_proof`
# validated only `body` and ignored both — signing a timestamp nobody reads is
# not replay defence, it is the shape of one. Bounded today by the single-use,
# 5-minute pairing code, so these tests pin defence-in-depth, not a hole.


def _pop_fields_with_envelope(
    code: str, device_priv: str, device_pub: str, envelope: dict
) -> dict:
    """Sign an ARBITRARY envelope with the device key — the signature is
    always valid, so what the endpoint rejects is the envelope's CONTENT and
    nothing else."""
    import json

    from axi import mesh_trust

    payload = json.dumps(
        envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")  # same canonical form `mesh_trust._canonical` produces
    return {
        "device_pubkey": device_pub,
        "pubkey_proof": mesh_trust.sign_request(device_priv, payload),
        "pubkey_proof_payload": base64.b64encode(payload).decode("ascii"),
    }


def test_pair_pop_with_a_stale_timestamp_is_refused(client):
    """An hour-old proof is refused even though its signature is perfect."""
    import time

    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    fields = _pop_fields_with_envelope(
        code,
        device_priv,
        device_pub,
        {
            "body": {"code": code, "device_pubkey": device_pub},
            "ts": int(time.time()) - 3600,
            "nonce": "a" * 32,
        },
    )

    r = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Stale", **fields}
    )

    assert r.status_code == 400
    assert "stale" in r.json()["detail"].lower()
    assert store.device_list() == []


def test_pair_pop_from_far_in_the_future_is_refused(client):
    """The window is symmetric: a clock an hour AHEAD is as unusable as one an
    hour behind, and accepting it would let a proof be minted for later."""
    import time

    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    fields = _pop_fields_with_envelope(
        code,
        device_priv,
        device_pub,
        {
            "body": {"code": code, "device_pubkey": device_pub},
            "ts": int(time.time()) + 3600,
            "nonce": "a" * 32,
        },
    )

    r = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Future", **fields}
    )

    assert r.status_code == 400
    assert "stale" in r.json()["detail"].lower()
    assert store.device_list() == []


def test_pair_pop_tolerates_ordinary_phone_clock_skew(client):
    """The other direction, and the reason the window is not tight: a phone
    whose clock is a minute off is an ORDINARY phone, not an attacker. A check
    that rejects it turns pairing into an unexplainable failure."""
    import time

    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    fields = _pop_fields_with_envelope(
        code,
        device_priv,
        device_pub,
        {
            "body": {"code": code, "device_pubkey": device_pub},
            "ts": int(time.time()) - 60,
            "nonce": "a" * 32,
        },
    )

    r = client.post(
        "/api/v1/pair", json={"code": code, "device_name": "Skewed", **fields}
    )

    assert r.status_code == 200, r.json()


def test_pair_pop_without_ts_or_nonce_is_refused(client):
    """A `body`-only envelope is not the envelope this scheme signs. Accepting
    it would let a caller opt OUT of the freshness fields simply by omitting
    them — the classic downgrade."""
    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()

    import time as _time

    for missing in ("ts", "nonce"):
        code = _mint_code(client)
        envelope = {
            "body": {"code": code, "device_pubkey": device_pub},
            "ts": int(_time.time()),
            "nonce": "a" * 32,
        }
        del envelope[missing]
        fields = _pop_fields_with_envelope(code, device_priv, device_pub, envelope)

        r = client.post(
            "/api/v1/pair", json={"code": code, "device_name": "Downgrade", **fields}
        )

        assert r.status_code == 400, f"missing {missing} was accepted"
        assert missing in r.json()["detail"].lower()
        assert store.device_list() == []


def test_pair_pop_with_a_junk_nonce_is_refused(client):
    """The nonce is what makes two proofs for the same code distinguishable —
    an empty or non-string one is a malformed envelope, not a nonce."""
    import time

    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()

    for junk in ("", 12345):
        code = _mint_code(client)
        fields = _pop_fields_with_envelope(
            code,
            device_priv,
            device_pub,
            {
                "body": {"code": code, "device_pubkey": device_pub},
                "ts": int(time.time()),
                "nonce": junk,
            },
        )

        r = client.post(
            "/api/v1/pair", json={"code": code, "device_name": "Junk", **fields}
        )

        assert r.status_code == 400, f"nonce {junk!r} was accepted"
        assert "nonce" in r.json()["detail"].lower()
        assert store.device_list() == []


def test_pair_stale_pop_does_not_burn_the_pairing_code(client):
    """Same anti-code-burning contract the signature check already honours:
    the new freshness check runs BEFORE redemption, so a user whose clock was
    wrong can fix it and retry with the same code."""
    import time

    from axi import mesh_trust

    device_priv, device_pub = mesh_trust.new_node_keypair()
    code = _mint_code(client)
    stale = _pop_fields_with_envelope(
        code,
        device_priv,
        device_pub,
        {
            "body": {"code": code, "device_pubkey": device_pub},
            "ts": int(time.time()) - 3600,
            "nonce": "a" * 32,
        },
    )
    assert (
        client.post(
            "/api/v1/pair", json={"code": code, "device_name": "Stale", **stale}
        ).status_code
        == 400
    )

    good = client.post(
        "/api/v1/pair",
        json={
            "code": code,
            "device_name": "Retry",
            **_pop_fields(code, device_priv, device_pub),
        },
    )

    assert good.status_code == 200, good.json()
