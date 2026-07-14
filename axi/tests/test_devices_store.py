"""Tests for the `devices` table + store.py leaf helpers (M0-2).

Devices are paired phones/tablets (design D5): server persists only the
SHA-256 hash of the per-device bearer token, never the raw token. The
table is purely additive (created idempotently by `init_db()`, mirroring
the `domain_node_map` bootstrap-table precedent).

Covers:
  - schema bootstrap: devices table exists after init_db()
  - device_add + device_get_by_token_hash round-trip
  - the raw token is never persisted anywhere in the row
  - device_id / token_hash uniqueness enforced (IntegrityError)
  - device_list excludes token_hash and orders newest-first
  - device_revoke is idempotent (soft-delete via revoked_at)
  - device_touch_last_seen updates last_seen_at
  - write_router.maybe_forward wiring: single_writer ON + not owner forwards
    device_add / device_revoke instead of writing directly (mirrors
    test_write_router.py's TestAddConversationRouting pattern)
"""
from __future__ import annotations

import sqlcipher3
import pytest

from axi import store, write_router


def test_devices_table_exists_after_init_db():
    """init_db() bootstraps the devices table (additive, idempotent)."""
    c = store._connect()
    row = c.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='devices'"
    ).fetchone()
    assert row is not None


def test_device_add_and_get_by_token_hash_round_trip():
    token = "raw-token-shown-once-abc123"
    store.device_add("dev-1", "Héctor's Pixel", token, device_pubkey="pk-1")

    fetched = store.device_get_by_token_hash(store.hash_device_token(token))
    assert fetched is not None
    assert fetched["device_id"] == "dev-1"
    assert fetched["name"] == "Héctor's Pixel"
    assert fetched["device_pubkey"] == "pk-1"
    assert fetched["revoked_at"] is None


def test_device_get_by_token_hash_unknown_returns_none():
    assert store.device_get_by_token_hash("nonexistent-hash") is None


def test_raw_token_never_persisted():
    """The raw bearer token must never appear anywhere in the stored row —
    only its SHA-256 hash. This is the core security property of D5."""
    token = "super-secret-raw-token-xyz"
    store.device_add("dev-2", "iPad", token)

    c = store._connect()
    row = c.execute("SELECT * FROM devices WHERE device_id = ?", ("dev-2",)).fetchone()
    assert row is not None
    for key in row.keys():
        assert row[key] != token, f"raw token leaked into column {key!r}"
    assert row["token_hash"] == store.hash_device_token(token)
    assert row["token_hash"] != token


def test_hash_device_token_is_deterministic_sha256():
    import hashlib

    token = "some-token"
    assert store.hash_device_token(token) == hashlib.sha256(token.encode("utf-8")).hexdigest()


def test_device_add_duplicate_device_id_raises():
    store.device_add("dup-id", "Phone A", "token-a")
    with pytest.raises(sqlcipher3.dbapi2.IntegrityError):
        store.device_add("dup-id", "Phone B", "token-b")


def test_device_add_duplicate_token_hash_raises():
    """Two different device_ids must never share a token_hash (UNIQUE constraint)."""
    store.device_add("dev-a", "Phone A", "same-token")
    with pytest.raises(sqlcipher3.dbapi2.IntegrityError):
        store.device_add("dev-b", "Phone B", "same-token")


def test_device_list_excludes_token_hash_and_orders_newest_first():
    store.device_add("dev-old", "Old Phone", "token-old")
    store.device_add("dev-new", "New Phone", "token-new")

    devices = store.device_list()
    assert [d["device_id"] for d in devices] == ["dev-new", "dev-old"]
    for d in devices:
        assert "token_hash" not in d


def test_device_list_include_revoked_false_excludes_revoked():
    store.device_add("dev-active", "Active", "token-active")
    store.device_add("dev-revoked", "Revoked", "token-revoked")
    store.device_revoke("dev-revoked")

    active_only = store.device_list(include_revoked=False)
    assert [d["device_id"] for d in active_only] == ["dev-active"]

    everything = store.device_list(include_revoked=True)
    assert {d["device_id"] for d in everything} == {"dev-active", "dev-revoked"}


def test_device_revoke_sets_revoked_at_and_is_idempotent():
    store.device_add("dev-r", "To Revoke", "token-r")

    assert store.device_revoke("dev-r") is True
    fetched = store.device_get_by_token_hash(store.hash_device_token("token-r"))
    first_revoked_at = fetched["revoked_at"]
    assert first_revoked_at is not None

    # Second revoke is a no-op: returns False, timestamp unchanged.
    assert store.device_revoke("dev-r") is False
    fetched_again = store.device_get_by_token_hash(store.hash_device_token("token-r"))
    assert fetched_again["revoked_at"] == first_revoked_at


def test_device_revoke_unknown_device_returns_false():
    assert store.device_revoke("no-such-device") is False


def test_device_touch_last_seen_updates_timestamp():
    store.device_add("dev-touch", "Touch Me", "token-touch")
    fetched = store.device_get_by_token_hash(store.hash_device_token("token-touch"))
    assert fetched["last_seen_at"] is None

    store.device_touch_last_seen("dev-touch")
    fetched = store.device_get_by_token_hash(store.hash_device_token("token-touch"))
    assert fetched["last_seen_at"] is not None


# ─────────────────── write_router.maybe_forward wiring (D10) ────────────────


class TestDeviceWriteRouting:
    """Mirrors test_write_router.py's TestAddConversationRouting pattern:
    single_writer ON + not owner routes leaf writes through maybe_forward
    instead of writing directly."""

    def test_end_to_end_forwarded_device_add(self, tmp_path, monkeypatch):
        sock_path = tmp_path / "write.sock"
        monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", sock_path)
        server = write_router.WriteServer(path=sock_path)
        server.start()
        try:
            monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
            assert write_router.is_owner() is False

            store.device_add("dev-forwarded", "Forwarded Phone", "token-fwd")

            fetched = store.device_get_by_token_hash(store.hash_device_token("token-fwd"))
            assert fetched is not None
            assert fetched["device_id"] == "dev-forwarded"
        finally:
            server.stop()

    def test_owner_short_circuits_direct_write(self, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)

        def _fail(*a, **kw):
            raise AssertionError("owner must not forward writes")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        store.device_add("dev-owner", "Owner Phone", "token-owner")
        fetched = store.device_get_by_token_hash(store.hash_device_token("token-owner"))
        assert fetched is not None

    def test_config_off_never_forwards(self, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: False)

        def _fail(*a, **kw):
            raise AssertionError("must not forward when single_writer is off")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        store.device_add("dev-off", "Off Phone", "token-off")
        fetched = store.device_get_by_token_hash(store.hash_device_token("token-off"))
        assert fetched is not None

    def test_revoke_forwards_when_enabled_and_not_owner(self, tmp_path, monkeypatch):
        sock_path = tmp_path / "write.sock"
        monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", sock_path)
        server = write_router.WriteServer(path=sock_path)
        server.start()
        try:
            # Add directly first (owner path) so the row exists before we flip
            # to non-owner for the revoke call.
            monkeypatch.setattr(write_router, "single_writer_enabled", lambda: False)
            store.device_add("dev-rev-fwd", "Revoke Fwd", "token-rev-fwd")

            monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
            assert write_router.is_owner() is False
            assert store.device_revoke("dev-rev-fwd") is True

            fetched = store.device_get_by_token_hash(store.hash_device_token("token-rev-fwd"))
            assert fetched["revoked_at"] is not None
        finally:
            server.stop()
