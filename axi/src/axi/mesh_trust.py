"""Mesh root-of-trust + node enrollment + peer-auth crypto core.

Security core of the LifeOS federation mesh (roadmap
`docs/prd/roadmap-on-device-and-federation.md` §2.2 node auth, §2.4.4 per-node
key handling, §4.3 decision **B**): the **owner passphrase** is the root of
trust. It gates *joining* the mesh and signs node-key enrollment, so an
attacker who merely lands on the VPN still cannot enroll a rogue node. Being on
the VPN is TRANSPORT, not IDENTITY.

This is a minimal PKI with the owner passphrase as the root:

  * **KDF** — a key-encryption-key (KEK) is derived from the owner passphrase
    with **Scrypt** (`cryptography.hazmat.primitives.kdf.scrypt`, n=2**15, r=8,
    p=1). argon2id is preferred when `argon2-cffi` is importable, else Scrypt.
    Only the salt + KDF params are stored, NEVER the passphrase.
  * **Mesh ROOT keypair** — **Ed25519**. The root PRIVATE key is encrypted at
    rest with the KEK via **AESGCM** (random 96-bit nonce; nonce+ciphertext
    stored). The plaintext root key and the passphrase are NEVER written to
    disk. ``mesh_id`` = sha256 hex of the raw root PUBLIC key.
  * **Node keypair** — Ed25519 per node; the node private key stays local.
  * **Enrollment** — :func:`enroll_node` unlocks the root key with the
    passphrase and signs a membership CERT (canonical JSON
    ``{node_pubkey, mesh_id, issued_at, expires_at}``) with a detached Ed25519
    signature by the root.
  * **Verification** — :func:`verify_membership` canonicalizes, checks the root
    signature, checks ``mesh_id`` matches the root pubkey, and checks expiry.
  * **Peer request auth** — :func:`sign_request` / :func:`verify_request`. The
    signed payload embeds a ``ts`` timestamp + ``nonce`` (see
    :func:`build_signed_payload`) so callers can enforce replay freshness; the
    timestamp is INSIDE the signed bytes. Freshness *enforcement* is a caller
    concern; the signed timestamp makes it possible.

Only vetted ``cryptography`` primitives are used — no invented crypto.

Storage: all key material lives under ``$XDG_STATE_HOME/axi/mesh/`` (i.e.
``~/.local/state/axi/mesh/``), mode 0700 dir / 0600 files, NEVER in the repo and
NEVER touching ``memory.db`` / the personal graph store. Paths are injectable
(``base_dir=``) so tests use ``tmp_path``.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

try:  # pragma: no cover - depends on optional dependency
    import argon2.low_level as _argon2_ll

    _HAVE_ARGON2 = True
except Exception:  # pragma: no cover
    _argon2_ll = None
    _HAVE_ARGON2 = False


# ── tunables (security-critical; do not weaken without review) ──────────────
# Scrypt n=2**17 (~128 MiB with r=8) meets current OWASP interactive guidance;
# argon2id (preferred) is used automatically when argon2-cffi is installed.
SCRYPT_N = 2**17
SCRYPT_R = 8
SCRYPT_P = 1
_KEK_LEN = 32  # AES-256
_SALT_LEN = 16
_NONCE_LEN = 12  # 96-bit GCM nonce
_DEFAULT_TTL_SECONDS = 90 * 24 * 3600  # 90-day membership cert
# NOTE: expiry is currently the ONLY way a membership cert stops being honoured
# — there is no revocation list yet (see verify_membership + roadmap §5 R13).
# The TTL was shortened from 1 year to 90 days as a partial mitigation so a
# leaked/compromised node key self-heals sooner. Real revocation is a pending
# follow-up.
_SCHEMA_VERSION = 1

# argon2id params (used only when argon2-cffi is available).
_ARGON2_TIME = 3
_ARGON2_MEMORY_KIB = 64 * 1024
_ARGON2_PARALLELISM = 1


class MeshTrustError(Exception):
    """Base error for the mesh trust core."""


class WrongPassphrase(MeshTrustError):
    """Raised when the owner passphrase fails to unlock the root key.

    No partial secret is leaked: the AESGCM tag check fails atomically before
    any plaintext is produced.
    """


class MeshNotInitialized(MeshTrustError):
    """Raised when mesh operations run before :func:`init_mesh`."""


# ─────────────────────────── storage layout ───────────────────────────


def mesh_dir(base_dir: str | os.PathLike[str] | None = None) -> Path:
    """Return the mesh key-material directory, creating it 0700 if needed.

    ``base_dir`` is injectable for tests; when ``None`` it resolves to
    ``$XDG_STATE_HOME/axi/mesh`` (default ``~/.local/state/axi/mesh``).
    """
    if base_dir is not None:
        root = Path(base_dir) / "mesh"
    else:
        state = os.environ.get("XDG_STATE_HOME") or str(
            Path.home() / ".local" / "state"
        )
        root = Path(state) / "axi" / "mesh"
    root.mkdir(parents=True, exist_ok=True)
    # Harden perms on OUR OWN state dirs (root.json inside is already 0600).
    # We chmod both the `axi` parent and the `mesh` leaf to 0700 so a shared
    # ~/.local/state does not leave key material listable. The XDG state root
    # itself is intentionally left alone (it is shared across apps).
    for _d in (root.parent, root):  # .../axi , .../axi/mesh
        try:
            _d.chmod(0o700)
        except OSError:  # pragma: no cover - non-POSIX fallback
            pass
    return root


def _root_path(base_dir: str | os.PathLike[str] | None) -> Path:
    return mesh_dir(base_dir) / "root.json"


def _write_secure(path: Path, data: bytes) -> None:
    """Write ``data`` to ``path`` with mode 0600 (owner read/write only)."""
    # Create with restrictive perms from the start (avoid a 0644 window).
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    try:
        path.chmod(0o600)
    except OSError:  # pragma: no cover
        pass


def _b64e(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _b64d(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))


# ─────────────────────────── KDF ───────────────────────────


def _derive_kek(passphrase: str, salt: bytes, params: dict[str, Any]) -> bytes:
    """Derive the 32-byte key-encryption-key from the passphrase.

    Uses argon2id when available (recorded as ``algo == "argon2id"``), else
    Scrypt. The algorithm + params are read from ``params`` so a file written
    with argon2id still unlocks on a host with argon2 present.
    """
    algo = params.get("algo", "scrypt")
    if algo == "argon2id":
        if not _HAVE_ARGON2:  # pragma: no cover - depends on host
            raise MeshTrustError(
                "root.json was sealed with argon2id but argon2-cffi is missing"
            )
        return _argon2_ll.hash_secret_raw(
            secret=passphrase.encode("utf-8"),
            salt=salt,
            time_cost=int(params["time_cost"]),
            memory_cost=int(params["memory_cost"]),
            parallelism=int(params["parallelism"]),
            hash_len=_KEK_LEN,
            type=_argon2_ll.Type.ID,
        )
    # Scrypt fallback (default).
    kdf = Scrypt(
        salt=salt,
        length=_KEK_LEN,
        n=int(params["n"]),
        r=int(params["r"]),
        p=int(params["p"]),
    )
    return kdf.derive(passphrase.encode("utf-8"))


def _fresh_kdf_params() -> dict[str, Any]:
    if _HAVE_ARGON2:
        return {
            "algo": "argon2id",
            "time_cost": _ARGON2_TIME,
            "memory_cost": _ARGON2_MEMORY_KIB,
            "parallelism": _ARGON2_PARALLELISM,
        }
    return {"algo": "scrypt", "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P}


# ─────────────────────────── canonicalization ───────────────────────────


def _canonical(obj: Any) -> bytes:
    """Deterministic, compact JSON encoding for signing/verifying."""
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


# ─────────────────────────── Ed25519 helpers ───────────────────────────


def _pub_from_hex(pub_hex: str) -> Ed25519PublicKey:
    return Ed25519PublicKey.from_public_bytes(bytes.fromhex(pub_hex))


def _priv_from_hex(priv_hex: str) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(bytes.fromhex(priv_hex))


def new_node_keypair(
    base_dir: str | os.PathLike[str] | None = None, *, store: bool = False
) -> tuple[str, str]:
    """Generate a fresh Ed25519 node keypair as ``(priv_hex, pub_hex)``.

    When ``store`` is True the private key is persisted locally at
    ``<mesh_dir>/node_key`` with mode 0600 (the node private key stays on the
    node). Callers who manage their own key storage can leave ``store`` False.
    """
    priv = Ed25519PrivateKey.generate()
    priv_raw = priv.private_bytes_raw()
    pub_raw = priv.public_key().public_bytes_raw()
    priv_hex, pub_hex = priv_raw.hex(), pub_raw.hex()
    if store:
        _write_secure(mesh_dir(base_dir) / "node_key", priv_hex.encode("ascii"))
        _write_secure(mesh_dir(base_dir) / "node_pub", pub_hex.encode("ascii"))
    return priv_hex, pub_hex


def load_node_keypair(
    base_dir: str | os.PathLike[str] | None = None,
) -> tuple[str, str]:
    """Load a previously stored node keypair as ``(priv_hex, pub_hex)``."""
    d = mesh_dir(base_dir)
    try:
        priv_hex = (d / "node_key").read_text(encoding="ascii").strip()
        pub_hex = (d / "node_pub").read_text(encoding="ascii").strip()
    except FileNotFoundError as exc:
        raise MeshNotInitialized("local node keypair is missing") from exc
    return priv_hex, pub_hex


def save_membership_certificate(
    cert_token: str, *, base_dir: str | os.PathLike[str] | None = None
) -> None:
    """Persist this node's membership certificate as owner-only mesh state."""
    _write_secure(mesh_dir(base_dir) / "membership_cert", cert_token.encode("ascii"))


def load_membership_certificate(
    base_dir: str | os.PathLike[str] | None = None,
) -> str:
    try:
        return (mesh_dir(base_dir) / "membership_cert").read_text(encoding="ascii").strip()
    except FileNotFoundError as exc:
        raise MeshNotInitialized("local membership certificate is missing") from exc


def load_local_identity(
    base_dir: str | os.PathLike[str] | None = None,
) -> tuple[str, str]:
    """Load the private node key and certificate, failing closed if incomplete."""
    private, public = load_node_keypair(base_dir)
    cert = load_membership_certificate(base_dir)
    try:
        cert_public = _decode_token(cert)[0]["node_pubkey"]
    except Exception as exc:  # malformed local state is not a usable identity
        raise MeshNotInitialized("local membership certificate is invalid") from exc
    if cert_public != public:
        raise MeshNotInitialized("local membership certificate does not match node key")
    return private, cert


# ─────────────────────────── mesh init ───────────────────────────


def init_mesh(
    passphrase: str, *, base_dir: str | os.PathLike[str] | None = None
) -> dict[str, str]:
    """Create the mesh root of trust, sealed by the owner passphrase.

    Generates the Ed25519 root keypair, derives a KEK from ``passphrase``, and
    stores ONLY: KDF params + salt, the AESGCM nonce+ciphertext of the root
    private key, the root public key (hex), and ``mesh_id``. The plaintext root
    private key and the passphrase are never written.

    Returns ``{"mesh_id", "root_pubkey"}``. Idempotent-guard: refuses to
    overwrite an existing ``root.json``.
    """
    if not passphrase:
        raise MeshTrustError("passphrase must be non-empty")

    path = _root_path(base_dir)
    if path.exists():
        raise MeshTrustError(f"mesh already initialized at {path}")

    root_priv = Ed25519PrivateKey.generate()
    root_priv_raw = root_priv.private_bytes_raw()
    root_pub_raw = root_priv.public_key().public_bytes_raw()

    salt = secrets.token_bytes(_SALT_LEN)
    kdf_params = _fresh_kdf_params()
    kek = _derive_kek(passphrase, salt, kdf_params)

    nonce = secrets.token_bytes(_NONCE_LEN)
    ciphertext = AESGCM(kek).encrypt(nonce, root_priv_raw, None)

    mesh_id = hashlib.sha256(root_pub_raw).hexdigest()
    doc = {
        "schema": _SCHEMA_VERSION,
        "mesh_id": mesh_id,
        "root_pubkey": root_pub_raw.hex(),
        "kdf": {"salt": _b64e(salt), **kdf_params},
        "root_enc": {"nonce": _b64e(nonce), "ciphertext": _b64e(ciphertext)},
    }
    _write_secure(path, _canonical(doc))
    return {"mesh_id": mesh_id, "root_pubkey": root_pub_raw.hex()}


def _load_root_doc(base_dir: str | os.PathLike[str] | None) -> dict[str, Any]:
    path = _root_path(base_dir)
    if not path.exists():
        raise MeshNotInitialized(f"no mesh root at {path}; run init_mesh first")
    return json.loads(path.read_text(encoding="utf-8"))


def _unlock_root_private_raw(
    passphrase: str, *, base_dir: str | os.PathLike[str] | None = None
) -> bytes:
    """Decrypt and return the raw 32-byte root private key (in memory only).

    Raises :class:`WrongPassphrase` if the passphrase is wrong (AESGCM tag
    mismatch) — atomically, before any plaintext is produced.
    """
    doc = _load_root_doc(base_dir)
    salt = _b64d(doc["kdf"]["salt"])
    kek = _derive_kek(passphrase, salt, doc["kdf"])
    nonce = _b64d(doc["root_enc"]["nonce"])
    ciphertext = _b64d(doc["root_enc"]["ciphertext"])
    try:
        return AESGCM(kek).decrypt(nonce, ciphertext, None)
    except InvalidTag as exc:
        raise WrongPassphrase("wrong passphrase: cannot unlock mesh root") from exc


def root_pubkey(base_dir: str | os.PathLike[str] | None = None) -> str:
    """Return the mesh root public key (hex) — public, no passphrase needed."""
    return _load_root_doc(base_dir)["root_pubkey"]


def mesh_id_of(root_pubkey_hex: str) -> str:
    """Derive ``mesh_id`` (sha256 hex) from a root public key hex string."""
    return hashlib.sha256(bytes.fromhex(root_pubkey_hex)).hexdigest()


# ─────────────────────────── token encode/decode ───────────────────────────


def _encode_token(cert: dict[str, Any], sig: bytes) -> str:
    """Encode ``{cert, sig}`` as a compact base64url token."""
    envelope = {"cert": cert, "sig": _b64e(sig)}
    return base64.urlsafe_b64encode(_canonical(envelope)).decode("ascii")


def _decode_token(token: str) -> tuple[dict[str, Any], bytes]:
    envelope = json.loads(base64.urlsafe_b64decode(token.encode("ascii")))
    return envelope["cert"], _b64d(envelope["sig"])


# ─────────────────────────── enrollment ───────────────────────────


def enroll_node(
    node_pubkey: str,
    passphrase: str,
    *,
    base_dir: str | os.PathLike[str] | None = None,
    ttl_seconds: int = _DEFAULT_TTL_SECONDS,
    now: float | None = None,
) -> str:
    """Sign a membership cert for ``node_pubkey`` using the owner passphrase.

    Unlocks the root private key with ``passphrase`` (raising
    :class:`WrongPassphrase` on mismatch), builds the canonical cert
    ``{node_pubkey, mesh_id, issued_at, expires_at}``, and returns a token that
    bundles the cert with the root's detached Ed25519 signature.
    """
    doc = _load_root_doc(base_dir)
    root_priv_raw = _unlock_root_private_raw(passphrase, base_dir=base_dir)
    root_priv = Ed25519PrivateKey.from_private_bytes(root_priv_raw)

    issued = int(now if now is not None else time.time())
    cert = {
        "node_pubkey": node_pubkey,
        "mesh_id": doc["mesh_id"],
        "issued_at": issued,
        "expires_at": issued + int(ttl_seconds),
    }
    sig = root_priv.sign(_canonical(cert))
    return _encode_token(cert, sig)


# ─────────────────────────── membership verification ───────────────────────


def verify_membership(
    cert_token: str,
    root_pubkey_hex: str,
    *,
    now: float | None = None,
) -> bool:
    """Return True iff ``cert_token`` is a valid, unexpired membership cert
    signed by the root behind ``root_pubkey_hex`` for THIS mesh.

    Checks (all must pass, any failure -> False, never raises on bad input):
      1. token decodes and has the required cert fields;
      2. the root Ed25519 signature over the canonical cert verifies;
      3. ``cert.mesh_id`` equals ``sha256(root_pubkey)`` (binds cert to mesh);
      4. the cert is not expired (``now < expires_at``).
    """
    try:
        cert, sig = _decode_token(cert_token)
        required = {"node_pubkey", "mesh_id", "issued_at", "expires_at"}
        if not required.issubset(cert):
            return False
        # (3) mesh binding — cert must belong to this root's mesh.
        if cert["mesh_id"] != mesh_id_of(root_pubkey_hex):
            return False
        # (2) root signature over the canonical cert.
        _pub_from_hex(root_pubkey_hex).verify(sig, _canonical(cert))
        # (4) expiry.
        # TODO(revocation): membership is honoured until the cert EXPIRES —
        # there is no revocation list, so a compromised/decommissioned node
        # cannot be kicked before its cert lapses. Inference-proxy access
        # (`mesh_infer`) currently relies on expiry ONLY. Real revocation
        # (signed revocation list / short-lived certs + renewal) is a pending
        # follow-up tracked in roadmap §5 R13; the 90-day TTL is a partial
        # stopgap. Add the revocation check HERE when it lands.
        ts = now if now is not None else time.time()
        if ts >= float(cert["expires_at"]):
            return False
        return True
    except Exception:
        # Any tamper / decode error / signature mismatch -> reject.
        return False


# ─────────────────────────── peer request auth ───────────────────────────


def build_signed_payload(
    body: Any, *, now: float | None = None, nonce: str | None = None
) -> bytes:
    """Build canonical payload bytes to be signed by a node.

    Embeds a ``ts`` (unix seconds) and a random ``nonce`` INSIDE the signed
    bytes so a verifying caller can reject stale/replayed requests. Freshness
    enforcement (nonce cache + max-age window) is a caller concern; signing the
    timestamp is what makes it enforceable.
    """
    envelope = {
        "body": body,
        "ts": int(now if now is not None else time.time()),
        "nonce": nonce or secrets.token_hex(16),
    }
    return _canonical(envelope)


def sign_request(node_privkey_hex: str, payload_bytes: bytes) -> str:
    """Sign ``payload_bytes`` with the node private key. Returns hex signature."""
    return _priv_from_hex(node_privkey_hex).sign(payload_bytes).hex()


def verify_request(
    payload_bytes: bytes,
    sig_hex: str,
    cert_token: str,
    root_pubkey_hex: str,
    *,
    now: float | None = None,
) -> bool:
    """Return True iff the request is authentic for this mesh.

    Two independent gates, BOTH required:
      1. the membership cert is valid for ``root_pubkey_hex``
         (:func:`verify_membership`); and
      2. ``sig_hex`` is a valid Ed25519 signature over ``payload_bytes`` by the
         cert's ``node_pubkey`` (the request signer IS the enrolled node).

    Any tamper / cross-mesh cert / wrong signer / decode error -> False.
    """
    try:
        if not verify_membership(cert_token, root_pubkey_hex, now=now):
            return False
        cert, _sig = _decode_token(cert_token)
        node_pub = _pub_from_hex(cert["node_pubkey"])
        node_pub.verify(bytes.fromhex(sig_hex), payload_bytes)
        return True
    except Exception:
        return False
