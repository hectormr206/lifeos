"""Holding the fetch open so RECEIVING is immediate too.

Sync already pushes within seconds of a local write, but the other device only
found out on its next poll — up to thirty seconds of "casi de inmediato" that
was really "pretty soon". The user asked for near-instant BETWEEN devices, and
half of that is the receiving end.

Long-polling is the whole change: the relay holds an empty fetch open for a few
seconds and answers the moment an envelope lands. No push service, no account,
nothing new for the relay to learn — it still cannot read a byte of what it
holds.

The properties that matter, and each is a way it could go wrong:

  * an envelope already waiting returns AT ONCE (a wait parameter must never
    add latency to a mailbox that has mail);
  * an empty mailbox with no wait returns at once too (old clients unchanged);
  * the hold has a CEILING, or a phone keeps a socket open for ever;
  * an envelope arriving mid-hold wakes it (that is the point);
  * the wait is CLAMPED, so a client cannot ask the relay to hold for an hour.
"""

from __future__ import annotations

import os
import threading
import time

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient

from app.main import build_app
from app.store import RelayStore


@pytest.fixture
def store(tmp_path) -> RelayStore:
    # Real wall-clock, not the frozen clock the other suite uses: this one is
    # about TIMING, and a stopped clock would make every hold look instant.
    return RelayStore(path=tmp_path / "relay.db", now=time.time)


@pytest.fixture
def client(store) -> TestClient:
    return TestClient(build_app(store=store, now=time.time))


def _key() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


def _pub_hex(key: Ed25519PrivateKey) -> str:
    return key.public_key().public_bytes(
        encoding=Encoding.Raw, format=PublicFormat.Raw
    ).hex()


def _headers(key: Ed25519PrivateKey, method: str, path: str, body: bytes = b"") -> dict[str, str]:
    from app.auth import signing_preimage

    ts = str(int(time.time()))
    nonce = os.urandom(8).hex()
    sig = key.sign(signing_preimage(method, path, ts, nonce, body)).hex()
    return {"X-Relay-Ts": ts, "X-Relay-Nonce": nonce, "X-Relay-Sig": sig}


def _claim(client: TestClient, mailbox: str, key: Ed25519PrivateKey):
    path = f"/v1/mailbox/{mailbox}"
    body = _pub_hex(key).encode()
    return client.put(path, content=body, headers=_headers(key, "PUT", path, body))


MAILBOX = "a" * 32


def _envelope(tag: int = 1) -> bytes:
    """version byte + 32-byte env id + 16-byte RECIPIENT + ciphertext.

    The recipient has to be this mailbox: the relay refuses an envelope
    addressed elsewhere, which is exactly the check that made the first draft
    of this test fail.
    """
    return bytes([1]) + bytes([tag]) * 32 + bytes.fromhex(MAILBOX) + b"x" * 32


def test_waiting_mail_returns_immediately(client):
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"
    body = _envelope()
    dep = client.post(path, content=body, headers=_headers(key, "POST", path, body))
    assert dep.status_code == 202, dep.text

    started = time.monotonic()
    r = client.get(f"{path}?wait=5", headers=_headers(key, "GET", path))
    elapsed = time.monotonic() - started

    assert r.status_code == 200
    assert len(r.json()["envelopes"]) == 1
    assert elapsed < 1.0, "a mailbox with mail must never be held"


def test_no_wait_still_returns_immediately(client):
    """Old clients send no `wait` and must behave exactly as before."""
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"

    started = time.monotonic()
    r = client.get(path, headers=_headers(key, "GET", path))

    assert r.status_code == 200
    assert r.json()["envelopes"] == []
    assert time.monotonic() - started < 1.0


def test_an_empty_hold_ends_by_itself(client):
    """A phone must not keep a socket open for ever waiting for nothing."""
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"

    started = time.monotonic()
    r = client.get(f"{path}?wait=2", headers=_headers(key, "GET", path))
    elapsed = time.monotonic() - started

    assert r.status_code == 200
    assert r.json()["envelopes"] == []
    assert 1.0 < elapsed < 6.0, "it must actually wait, and actually stop"


def test_an_envelope_arriving_mid_hold_wakes_it(client, store):
    """THE point: the receiver hears about it without waiting for its turn."""
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"

    def deposit_soon():
        time.sleep(0.6)
        store.deposit(MAILBOX, "b" * 64, _envelope(2))

    threading.Thread(target=deposit_soon, daemon=True).start()

    started = time.monotonic()
    r = client.get(f"{path}?wait=8", headers=_headers(key, "GET", path))
    elapsed = time.monotonic() - started

    assert len(r.json()["envelopes"]) == 1
    assert elapsed < 4.0, "it should return on arrival, not on timeout"


def test_the_wait_is_clamped(client):
    """A client must not be able to ask the relay to hold a socket for an hour."""
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"

    started = time.monotonic()
    r = client.get(f"{path}?wait=3600", headers=_headers(key, "GET", path))

    assert r.status_code == 200
    assert time.monotonic() - started < 40, "the ceiling is the relay's, not the caller's"


def test_a_nonsense_wait_is_not_an_error(client):
    """Garbage in the query string must not cost the user a sync."""
    key = _key()
    _claim(client, MAILBOX, key)
    path = f"/v1/mailbox/{MAILBOX}/envelopes"

    r = client.get(f"{path}?wait=abc", headers=_headers(key, "GET", path))

    assert r.status_code == 200
