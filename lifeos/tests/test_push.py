"""Tests for lifeos.push — keypair persistence + subscriptions DAO.

The actual webpush network calls are not exercised here (would require a real
PWA endpoint). The wiring around storage and key generation is.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_vapid_keys_generated_once_and_persisted() -> None:
    import base64
    from lifeos.push import get_vapid_keys, _vapid_path

    k1 = get_vapid_keys()
    assert k1.public_b64url
    assert k1.private_b64url
    # Private key is the raw 32-byte EC scalar, b64url-encoded
    pad = "=" * (-len(k1.private_b64url) % 4)
    assert len(base64.urlsafe_b64decode(k1.private_b64url + pad)) == 32

    # Same call returns same keys
    k2 = get_vapid_keys()
    assert k1.public_b64url == k2.public_b64url
    assert k1.private_b64url == k2.private_b64url

    # On-disk JSON exists
    p = _vapid_path()
    assert p.exists()
    data = json.loads(p.read_text())
    assert data["public_b64url"] == k1.public_b64url
    assert data["private_b64url"] == k1.private_b64url


def test_vapid_public_key_decodes_to_65_bytes() -> None:
    """Uncompressed P-256 point format expected by browsers."""
    import base64
    from lifeos.push import get_vapid_keys

    k = get_vapid_keys()
    # b64url decode, padding-tolerant
    pad = "=" * (-len(k.public_b64url) % 4)
    raw = base64.urlsafe_b64decode(k.public_b64url + pad)
    assert len(raw) == 65
    assert raw[0] == 0x04  # uncompressed point marker


def test_subscription_upsert_and_list() -> None:
    from lifeos.push import add_subscription, list_subscriptions

    rid1 = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/A",
        p256dh="key1", auth="auth1", user_agent="ua-A",
    )
    rid2 = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/B",
        p256dh="key2", auth="auth2",
    )
    assert rid1 != rid2

    subs = list_subscriptions()
    assert len(subs) == 2

    # Upsert: same endpoint just refreshes p256dh/auth
    rid1_again = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/A",
        p256dh="key1_NEW", auth="auth1_NEW",
    )
    assert rid1_again == rid1
    subs = list_subscriptions()
    assert len(subs) == 2  # still 2 — upsert, not new
    a = [s for s in subs if s["endpoint"].endswith("/A")][0]
    assert a["p256dh"] == "key1_NEW"


def test_remove_subscription() -> None:
    from lifeos.push import add_subscription, list_subscriptions, remove_subscription

    add_subscription(endpoint="https://x/y", p256dh="k", auth="a")
    assert len(list_subscriptions()) == 1
    remove_subscription("https://x/y")
    assert len(list_subscriptions()) == 0
