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
    assert mesh_trust.verify_membership(cert, info["root_pubkey"]) is True


def test_sign_and_verify_request_true(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync", "cursor": 7})
    sig = mesh_trust.sign_request(node_priv, payload)
    assert (
        mesh_trust.verify_request(payload, sig, cert, info["root_pubkey"]) is True
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
    assert mesh_trust.verify_membership(forged, info["root_pubkey"]) is False


def test_tampered_mesh_id_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    forged = _mutate_cert(cert, "mesh_id", "0" * 64)
    assert mesh_trust.verify_membership(forged, info["root_pubkey"]) is False


def test_tampered_expiry_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    # Extend expiry far into the future -> signature no longer matches.
    forged = _mutate_cert(cert, "expires_at", int(time.time()) + 10_000_000)
    assert mesh_trust.verify_membership(forged, info["root_pubkey"]) is False


# ─────────────────────────── forged signature (different root) ─────────


def test_forged_signature_from_different_root_rejected(tmp_path):
    info_a = mesh_trust.init_mesh(PASS, base_dir=tmp_path / "a")
    # A second, independent mesh with its own root.
    info_b = mesh_trust.init_mesh(PASS, base_dir=tmp_path / "b")
    _p, node_pub = mesh_trust.new_node_keypair()
    # Cert signed by mesh B's root...
    cert_b = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path / "b")
    # ...verified against mesh A's root pubkey must fail.
    assert mesh_trust.verify_membership(cert_b, info_a["root_pubkey"]) is False
    # And it correctly verifies under its own root.
    assert mesh_trust.verify_membership(cert_b, info_b["root_pubkey"]) is True


# ─────────────────────────── expired cert ───────────────────────────


def test_expired_cert_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _p, node_pub = mesh_trust.new_node_keypair()
    # Issue a cert that already expired (negative ttl).
    cert = mesh_trust.enroll_node(
        node_pub, PASS, base_dir=tmp_path, ttl_seconds=-1
    )
    assert mesh_trust.verify_membership(cert, info["root_pubkey"]) is False


# ─────────────────────────── peer request auth ───────────────────────────


def test_verify_request_wrong_payload_rejected(tmp_path):
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    payload = mesh_trust.build_signed_payload({"op": "sync"})
    sig = mesh_trust.sign_request(node_priv, payload)
    tampered = payload + b"x"
    assert (
        mesh_trust.verify_request(tampered, sig, cert, info["root_pubkey"])
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
        mesh_trust.verify_request(payload, sig, cert, info["root_pubkey"])
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
        mesh_trust.verify_request(payload, sig, cert_b, info_a["root_pubkey"])
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
