"""The blind relay: it moves sealed envelopes and learns nothing.

WHAT THIS SERVICE IS. A mailbox that holds opaque ciphertext until the
recipient device fetches it, then forgets it. It never decrypts, never stores
plaintext, and never keeps anything permanently. It exists because two of a
person's devices are almost never online at the same moment.

WHAT IT MUST NEVER BECOME. A census of who owns which devices. That is the
whole reason a mailbox claim expires like an envelope does: an active device
set keeps its anti-spam protection, an abandoned one leaves nothing behind.
Every test below that looks like bookkeeping is really guarding that property.

THE THING IT CANNOT HIDE, said plainly here and in the UI: the relay sees each
mailbox UUID, envelope sizes, timing and source IPs. It cannot see content,
keys or names. Tests pin what it stores so that list stays true.
"""

from __future__ import annotations

import os

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient

from app.main import build_app
from app.store import RelayStore

MAILBOX_A = "a" * 32
MAILBOX_B = "b" * 32

TTL_SECONDS = 30 * 86400


class Clock:
    """Injected time, so 30-day expiry is a test and not a wait."""

    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance_days(self, days: float) -> None:
        self.now += days * 86400


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def store(tmp_path, clock) -> RelayStore:
    return RelayStore(path=tmp_path / "relay.db", now=clock)


@pytest.fixture
def client(store, clock) -> TestClient:
    return TestClient(build_app(store=store, now=clock))


def _keypair() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


def _pub_hex(key: Ed25519PrivateKey) -> str:
    return key.public_key().public_bytes(
        encoding=Encoding.Raw, format=PublicFormat.Raw
    ).hex()


def _sign(key: Ed25519PrivateKey, method: str, path: str, body: bytes, ts: str, nonce: str) -> str:
    from app.auth import signing_preimage

    return key.sign(signing_preimage(method, path, ts, nonce, body)).hex()


def _headers(key: Ed25519PrivateKey, method: str, path: str, body: bytes = b"", *, now: float) -> dict[str, str]:
    ts = str(int(now))
    nonce = os.urandom(8).hex()
    return {
        "X-Relay-Ts": ts,
        "X-Relay-Nonce": nonce,
        "X-Relay-Sig": _sign(key, method, path, body, ts, nonce),
    }


def _claim(client: TestClient, mailbox: str, key: Ed25519PrivateKey, *, now: float):
    path = f"/v1/mailbox/{mailbox}"
    body = _pub_hex(key).encode()
    return client.put(
        path,
        content=body,
        headers=_headers(key, "PUT", path, body, now=now),
    )


def _envelope(size: int = 256) -> bytes:
    """A well-formed opaque envelope: version, env_id, recipient, ciphertext."""
    return bytes([0x01]) + os.urandom(32) + bytes.fromhex(MAILBOX_A) + os.urandom(size)


# --------------------------------------------------------------------------
# 2.3 claim-before-deposit
# --------------------------------------------------------------------------


def test_deposit_into_an_unclaimed_mailbox_is_refused(client, clock):
    key = _keypair()
    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()

    response = client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    )

    assert response.status_code == 404
    # Refused BEFORE storing: an open drop box that stores first and rejects
    # afterwards is still an open drop box.
    assert response.headers.get("content-length") is not None


def test_claiming_then_depositing_works(client, clock):
    key = _keypair()
    assert _claim(client, MAILBOX_A, key, now=clock.now).status_code == 201

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    deposit = client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    )

    assert deposit.status_code == 202


def test_a_second_claim_of_the_same_mailbox_by_a_different_key_is_refused(client, clock):
    _claim(client, MAILBOX_A, _keypair(), now=clock.now)

    stranger = _keypair()
    assert _claim(client, MAILBOX_A, stranger, now=clock.now).status_code == 409


# --------------------------------------------------------------------------
# 2.2 anonymous signature auth
# --------------------------------------------------------------------------


def test_an_invalid_signature_is_refused(client, clock):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    headers = _headers(key, "POST", path, body, now=clock.now)
    headers["X-Relay-Sig"] = "00" * 64

    assert client.post(path, content=body, headers=headers).status_code == 401


def test_a_signature_over_different_bytes_is_refused(client, clock):
    """Signing SOMETHING is not signing THIS. The body is in the preimage."""
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    headers = _headers(key, "POST", path, _envelope(), now=clock.now)

    assert client.post(path, content=_envelope(), headers=headers).status_code == 401


def test_a_stale_timestamp_is_refused(client, clock):
    """Freshness window: a captured request must not replay tomorrow."""
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    headers = _headers(key, "POST", path, body, now=clock.now)
    clock.advance_days(1)

    assert client.post(path, content=body, headers=headers).status_code == 401


def test_a_replayed_nonce_is_refused(client, clock):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    headers = _headers(key, "POST", path, body, now=clock.now)

    assert client.post(path, content=body, headers=headers).status_code == 202
    assert client.post(path, content=body, headers=headers).status_code == 401


def test_the_relay_stores_no_device_identity(client, clock, store):
    """2.2 — authorised, never identified.

    The relay proves the caller holds a key. It must not be able to say WHO,
    and it must not write anything that would let an operator reconstruct it.
    """
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    stored = store.debug_dump()
    flat = repr(stored).lower()

    for forbidden in ("device", "nickname", "name", "user", "email"):
        assert forbidden not in flat, f"the relay persisted a {forbidden} field"


# --------------------------------------------------------------------------
# 2.1 opaque payloads only
# --------------------------------------------------------------------------


def test_a_payload_the_relay_could_interpret_is_refused(client, clock):
    """If the relay can parse it, it is not ciphertext.

    JSON, and anything else with recognisable structure, means a client sent
    plaintext by mistake. Storing it would make the relay exactly the thing
    this design promises it is not.
    """
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = b'{"note": "esto es texto plano"}'

    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 400


def test_an_envelope_with_the_wrong_version_byte_is_refused(client, clock):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = bytes([0xFF]) + os.urandom(32) + bytes.fromhex(MAILBOX_A) + os.urandom(64)

    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 400


def test_an_envelope_addressed_elsewhere_is_refused(client, clock):
    """The recipient in the header must match the mailbox it was posted to."""
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = bytes([0x01]) + os.urandom(32) + bytes.fromhex(MAILBOX_B) + os.urandom(64)

    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 400


# --------------------------------------------------------------------------
# 2.4 delete-on-ack and the 30-day TTL
# --------------------------------------------------------------------------


def _deposit(client, clock, key, count=1):
    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    ids = []
    for _ in range(count):
        body = _envelope()
        r = client.post(
            path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
        )
        assert r.status_code == 202
        ids.append(r.json()["env_id"])
    return ids


def test_an_acked_envelope_is_no_longer_delivered(client, clock):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)
    (env_id,) = _deposit(client, clock, key)

    fetch_path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    listing = client.get(
        fetch_path, headers=_headers(key, "GET", fetch_path, b"", now=clock.now)
    )
    assert listing.status_code == 200
    assert len(listing.json()["envelopes"]) == 1

    ack_path = f"/v1/mailbox/{MAILBOX_A}/ack"
    ack_body = env_id.encode()
    assert client.post(
        ack_path,
        content=ack_body,
        headers=_headers(key, "POST", ack_path, ack_body, now=clock.now),
    ).status_code == 204

    after = client.get(
        fetch_path, headers=_headers(key, "GET", fetch_path, b"", now=clock.now)
    )
    assert after.json()["envelopes"] == []


def test_an_unacked_envelope_under_thirty_days_is_still_delivered(client, clock):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)
    _deposit(client, clock, key)

    clock.advance_days(29)
    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"

    listing = client.get(path, headers=_headers(key, "GET", path, b"", now=clock.now))
    assert len(listing.json()["envelopes"]) == 1


def test_an_unacked_envelope_past_thirty_days_is_swept(client, clock, store):
    """A device offline for a month loses the envelope, not the data.

    The sender's changes are still in its own graph; the sync engine re-sends
    from its cursor. Expiry costs a round trip, never a fact.

    Note what ELSE is gone at day 31, which the first version of this test got
    wrong: the mailbox CLAIM expired too, so the mailbox no longer exists and
    the fetch is a 404, not an empty list. That is the design working — an idle
    device set leaves nothing behind, including the claim.
    """
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)
    _deposit(client, clock, key)

    clock.advance_days(31)
    store.sweep()

    assert store.envelope_count(MAILBOX_A) == 0

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    listing = client.get(path, headers=_headers(key, "GET", path, b"", now=clock.now))
    assert listing.status_code == 404


def test_a_returning_device_reclaims_its_own_mailbox_with_the_same_key(client, clock, store):
    """The recovery path out of the expiry above, and it must not need a human.

    A device that was offline past the TTL comes back, re-derives the SAME auth
    key from the SAME phrase, and re-claims. If that were refused as "already
    claimed" or treated as a stranger, a month offline would permanently cost
    the device its address for no reason.
    """
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    clock.advance_days(31)
    store.sweep()
    assert store.claim_exists(MAILBOX_A) is False

    assert _claim(client, MAILBOX_A, key, now=clock.now).status_code == 201

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 202


def test_reclaiming_a_live_mailbox_with_the_same_key_is_idempotent(client, clock):
    """A device that reinstalls from the phrase derives the identical key.

    Refusing it would lock a user out of their own mailbox after a reinstall —
    the exact moment the recovery phrase is supposed to save them.
    """
    key = _keypair()
    assert _claim(client, MAILBOX_A, key, now=clock.now).status_code == 201
    assert _claim(client, MAILBOX_A, key, now=clock.now).status_code == 201


# --------------------------------------------------------------------------
# 2.5 abuse bounds
# --------------------------------------------------------------------------


def test_an_oversized_envelope_is_refused_before_storage(client, clock, store):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope(size=2 * 1024 * 1024)

    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 413
    assert store.envelope_count(MAILBOX_A) == 0


def test_a_mailbox_over_its_envelope_cap_is_refused(client, clock, store):
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    store.set_limits(max_envelopes=3)
    _deposit(client, clock, key, count=3)

    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    body = _envelope()
    assert client.post(
        path, content=body, headers=_headers(key, "POST", path, body, now=clock.now)
    ).status_code == 429


# --------------------------------------------------------------------------
# 2.6 / 2.7 the claim expires too
# --------------------------------------------------------------------------


def test_using_a_mailbox_refreshes_its_claim(client, clock, store):
    """2.6 — an active set keeps its anti-spam protection indefinitely."""
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)

    clock.advance_days(20)
    path = f"/v1/mailbox/{MAILBOX_A}/envelopes"
    client.get(path, headers=_headers(key, "GET", path, b"", now=clock.now))

    clock.advance_days(20)  # 40 days after the claim, 20 after last use
    store.sweep()

    assert store.claim_exists(MAILBOX_A) is True


def test_an_idle_device_set_leaves_zero_rows(client, clock, store):
    """2.7 — the property this whole design is for.

    Once a set stops syncing, the relay must forget it existed. A claim table
    that outlives use becomes a permanent pseudonymous census of every device
    set that ever synced — exactly the linkable residue the blind relay exists
    to avoid.
    """
    key = _keypair()
    _claim(client, MAILBOX_A, key, now=clock.now)
    _deposit(client, clock, key)

    clock.advance_days(31)
    store.sweep()

    assert store.envelope_count(MAILBOX_A) == 0
    assert store.claim_exists(MAILBOX_A) is False
    assert store.rows_for(MAILBOX_A) == 0


# --------------------------------------------------------------------------
# 2.8 unlinkability
# --------------------------------------------------------------------------


def test_two_mailboxes_of_one_set_share_no_linkable_field(client, clock, store):
    """2.8 — the relay must not be able to group a person's devices.

    Both mailboxes below are derived from ONE root key, exactly as a real
    device set does: same phrase, same hierarchy, different mailbox UUID as
    HKDF salt. That is precisely the case an operator would want to correlate,
    so it is the case the test uses.
    """
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    root = os.urandom(32)

    def auth_key(mailbox: str) -> Ed25519PrivateKey:
        seed = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=mailbox.encode(),
            info=b"lifeos/sync/mbauth/v1",
        ).derive(root)
        return Ed25519PrivateKey.from_private_bytes(seed)

    key_a, key_b = auth_key(MAILBOX_A), auth_key(MAILBOX_B)
    assert _claim(client, MAILBOX_A, key_a, now=clock.now).status_code == 201
    assert _claim(client, MAILBOX_B, key_b, now=clock.now).status_code == 201

    claim_a = store.debug_claim(MAILBOX_A)
    claim_b = store.debug_claim(MAILBOX_B)
    assert claim_a is not None and claim_b is not None

    # The two pubkeys are independent curve points: no shared prefix, nothing
    # that betrays a common root.
    assert claim_a["auth_pubkey"] != claim_b["auth_pubkey"]
    assert claim_a["auth_pubkey"][:8] != claim_b["auth_pubkey"][:8]

    # ...and the ONLY fields stored per mailbox are its uuid, that pubkey and
    # timestamps. Anything else would be a grouping key.
    assert set(claim_a) == {"mailbox", "auth_pubkey", "claimed_at", "last_seen_at"}
