"""Tests for the mesh root-of-trust + node enrollment + peer-auth crypto core.

Security core of the LifeOS federation mesh (roadmap
`docs/prd/roadmap-on-device-and-federation.md` §2.2 node auth, §2.4.4 root of
trust, §4.3 decision "B"): the OWNER PASSPHRASE gates enrollment. Being on the
VPN is transport, NOT identity.

These tests are deliberately adversarial: wrong passphrase, tampered certs,
forged signatures, expired certs, cross-mesh certs, and a plaintext-secret
leak check on the at-rest state file.

Only vetted `cryptography` primitives are exercised (Ed25519 + AESGCM + Scrypt
KDF). No invented crypto.
"""
from __future__ import annotations

import json
import time

import pytest

from axi import mesh_trust


PASS = "correct horse battery staple"


# ─────────────────────────── happy path ───────────────────────────


def test_init_mesh_creates_root_and_mesh_id(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    assert isinstance(info["mesh_id"], str) and len(info["mesh_id"]) == 64
    # mesh_id is the sha256 hex of the raw root public key.
    assert isinstance(info["root_pubkey"], str) and info["root_pubkey"]
    # State file exists and is owner-only (0600).
    state = mesh_trust.mesh_dir(tmp_path) / "root.json"
    assert state.exists()
    assert (state.stat().st_mode & 0o777) == 0o600


def test_enroll_and_verify_membership_true(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    assert mesh_trust.verify_membership(cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is True


def test_local_membership_certificate_is_owner_only(tmp_path):
    token = "synthetic-membership-token"
    mesh_trust.save_membership_certificate(token, base_dir=tmp_path)
    path = mesh_trust.mesh_dir(tmp_path) / "membership_cert"
    assert mesh_trust.load_membership_certificate(tmp_path) == token
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700


def test_local_identity_fails_closed_when_key_or_certificate_missing(tmp_path):
    mesh_trust.new_node_keypair(tmp_path, store=True)
    with pytest.raises(mesh_trust.MeshNotInitialized, match="membership certificate"):
        mesh_trust.load_local_identity(tmp_path)

    other = tmp_path / "certificate-only"
    mesh_trust.save_membership_certificate("certificate", base_dir=other)
    with pytest.raises(mesh_trust.MeshNotInitialized, match="node keypair"):
        mesh_trust.load_local_identity(other)


def test_sign_and_verify_request_true(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync", "cursor": 7})
    sig = mesh_trust.sign_request(node_priv, payload)
    assert (
        mesh_trust.verify_request(payload, sig, cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is True
    )


# ─────────────────────────── wrong passphrase ───────────────────────────


def test_wrong_passphrase_cannot_unlock_root(tmp_path):
    mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _priv, node_pub = mesh_trust.new_node_keypair()
    with pytest.raises(mesh_trust.WrongPassphrase):
        mesh_trust.enroll_node(node_pub, "not the passphrase", base_dir=tmp_path)


# ─────────────────────────── tampered cert ───────────────────────────


def _mutate_cert(cert_token: str, field: str, value) -> str:
    cert, sig = mesh_trust._decode_token(cert_token)
    cert[field] = value
    return mesh_trust._encode_token(cert, sig)


def test_tampered_node_pubkey_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    _p2, other_pub = mesh_trust.new_node_keypair()
    forged = _mutate_cert(cert, "node_pubkey", other_pub)
    assert mesh_trust.verify_membership(forged, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is False


def test_tampered_mesh_id_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    forged = _mutate_cert(cert, "mesh_id", "0" * 64)
    assert mesh_trust.verify_membership(forged, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is False


def test_tampered_expiry_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    # Extend expiry far into the future -> signature no longer matches.
    forged = _mutate_cert(cert, "expires_at", int(time.time()) + 10_000_000)
    assert mesh_trust.verify_membership(forged, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is False


# ─────────────────────────── forged signature (different root) ─────────


def test_forged_signature_from_different_root_rejected(tmp_path):
    info_a = mesh_trust.init_mesh(PASS, base_dir=tmp_path / "a")
    # A second, independent mesh with its own root.
    info_b = mesh_trust.init_mesh(PASS, base_dir=tmp_path / "b")
    _p, node_pub = mesh_trust.new_node_keypair()
    # Cert signed by mesh B's root...
    cert_b = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path / "b")
    # ...verified against mesh A's root pubkey must fail.
    assert (
        mesh_trust.verify_membership(
            cert_b, info_a["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK
        )
        is False
    )
    # And it correctly verifies under its own root.
    assert (
        mesh_trust.verify_membership(
            cert_b, info_b["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK
        )
        is True
    )


# ─────────────────────────── expired cert ───────────────────────────


def test_expired_cert_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    # Issue a cert that already expired (negative ttl).
    cert = mesh_trust.enroll_node(
        node_pub, PASS, base_dir=tmp_path, ttl_seconds=-1
    )
    assert mesh_trust.verify_membership(cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK) is False


# ─────────────────────────── peer request auth ───────────────────────────


def test_verify_request_wrong_payload_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(node_priv, payload)
    tampered = payload + b"x"
    assert (
        mesh_trust.verify_request(tampered, sig, cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK)
        is False
    )


def test_verify_request_wrong_signer_rejected(tmp_path):
    """A payload signed by a key that is NOT the cert's node_pubkey fails."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    attacker_priv, _attacker_pub = mesh_trust.new_node_keypair()
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(attacker_priv, payload)
    assert (
        mesh_trust.verify_request(payload, sig, cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK)
        is False
    )


def test_verify_request_cross_mesh_cert_rejected(tmp_path):
    info_a = mesh_trust.init_mesh(PASS, base_dir=tmp_path / "a")
    mesh_trust.init_mesh(PASS, base_dir=tmp_path / "b")
    node_priv, node_pub = mesh_trust.new_node_keypair()
    # Cert from mesh B, request verified against mesh A's root -> reject.
    cert_b = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path / "b")
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(node_priv, payload)
    assert (
        mesh_trust.verify_request(
            payload, sig, cert_b, info_a["root_pubkey"],
            is_revoked=mesh_trust.NO_REVOCATION_CHECK,
        )
        is False
    )


def test_signed_payload_carries_timestamp_for_replay_defense(tmp_path):
    """The signed payload MUST embed a timestamp (and nonce) so callers can
    enforce freshness. The timestamp is inside the signed bytes."""
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    obj = json.loads(payload.decode("utf-8"))
    assert "ts" in obj and isinstance(obj["ts"], (int, float))
    assert "nonce" in obj and obj["nonce"]
    assert obj["body"] == {"op": "sync"}


# ─────────────────────────── revocation (fail-closed) ───────────────────


def test_revoked_device_fails_verification_within_validity_window(tmp_path):
    """Scenario: revoked-within-validity-window (spec `mesh-trust-hardening`).

    An otherwise-valid, UNEXPIRED cert must still be rejected once its device
    has been revoked — expiry is not the only way membership stops."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    assert (
        mesh_trust.verify_membership(
            cert, info["root_pubkey"], is_revoked=lambda pk: True
        )
        is False
    )


def test_revocation_is_rechecked_every_call_not_cached(tmp_path):
    """Verifying twice with the SAME cert must reflect a revocation that
    happened in between — no caching of the revocation decision."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    revoked = {"flag": False}
    is_revoked = lambda pk: revoked["flag"]  # noqa: E731 - test-local

    assert (
        mesh_trust.verify_membership(cert, info["root_pubkey"], is_revoked=is_revoked)
        is True
    )
    revoked["flag"] = True
    assert (
        mesh_trust.verify_membership(cert, info["root_pubkey"], is_revoked=is_revoked)
        is False
    )


def test_non_revoked_device_with_valid_cert_still_passes(tmp_path):
    """An injected `is_revoked` that reports False must not block a valid cert."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    assert (
        mesh_trust.verify_membership(
            cert, info["root_pubkey"], is_revoked=lambda pk: False
        )
        is True
    )


def test_is_revoked_callback_raising_fails_closed(tmp_path, caplog):
    """A revocation source that cannot be read must FAIL CLOSED (reject),
    never silently treat the device as fine — and it must log loudly."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)

    def _boom(pk):
        raise RuntimeError("revocation store unreachable")

    with caplog.at_level("ERROR", logger="axi.mesh_trust"):
        result = mesh_trust.verify_membership(
            cert, info["root_pubkey"], is_revoked=_boom
        )
    assert result is False
    assert any("revocation" in rec.message.lower() for rec in caplog.records)


def test_verify_membership_accepts_no_revocation_check_sentinel(tmp_path):
    """`NO_REVOCATION_CHECK` is the explicit, greppable opt-out — a caller
    that genuinely has no revocation source passes THIS, not nothing, and
    gets the pre-hardening behaviour (expiry/signature-only checks)."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    assert (
        mesh_trust.verify_membership(
            cert, info["root_pubkey"], is_revoked=mesh_trust.NO_REVOCATION_CHECK
        )
        is True
    )


def test_verify_membership_requires_is_revoked_kwarg(tmp_path):
    """`is_revoked` has NO default — omitting it must fail LOUDLY (TypeError)
    at the call site. A revocation check that can be skipped by forgetting a
    keyword argument is exactly the silent degradation this guards against."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    with pytest.raises(TypeError):
        mesh_trust.verify_membership(cert, info["root_pubkey"])


def test_verify_request_requires_is_revoked_kwarg(tmp_path):
    """Same contract one layer up: `verify_request` also has no default."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(node_priv, payload)
    with pytest.raises(TypeError):
        mesh_trust.verify_request(payload, sig, cert, info["root_pubkey"])


def test_verify_request_threads_is_revoked_through_to_membership(tmp_path):
    """`verify_request` must forward `is_revoked` to `verify_membership` so a
    revoked node fails peer-request auth too, not just membership checks."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(node_priv, payload)
    assert (
        mesh_trust.verify_request(
            payload, sig, cert, info["root_pubkey"], is_revoked=lambda pk: True
        )
        is False
    )


# ─────────────────────────── no plaintext secrets at rest ─────────────


def test_root_private_key_not_stored_in_plaintext(tmp_path):
    """The raw Ed25519 root private key bytes must NOT appear on disk, and the
    passphrase must never be written."""
    mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    # Recover the raw private key via the passphrase (in-memory only).
    raw_priv = mesh_trust._unlock_root_private_raw(PASS, base_dir=tmp_path)
    assert len(raw_priv) == 32

    state = mesh_trust.mesh_dir(tmp_path) / "root.json"
    blob = state.read_bytes()
    # The plaintext private key bytes are absent from the at-rest file.
    assert raw_priv not in blob
    # The passphrase is never written to disk.
    assert PASS.encode("utf-8") not in blob
    # Sanity: the file is JSON with kdf params + encrypted material, no
    # plaintext private key field.
    doc = json.loads(blob.decode("utf-8"))
    assert doc["kdf"]["algo"] == "scrypt"
    assert "salt" in doc["kdf"]
    assert "nonce" in doc["root_enc"] and "ciphertext" in doc["root_enc"]
    assert "root_private" not in doc and "private_key" not in doc
