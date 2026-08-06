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


# ──────────────── proof-of-possession migration (pubkey_proven) ─────────────


def test_device_add_defaults_pubkey_proven_false():
    """A freshly-paired device with no PoP is stored unproven by default."""
    store.device_add("dev-unproven", "New Phone", "tok-unproven", device_pubkey="pk-u")
    fetched = store.device_get_by_token_hash(store.hash_device_token("tok-unproven"))
    assert fetched["pubkey_proven"] == 0


def test_device_add_records_pubkey_proven_true_when_pop_verified():
    store.device_add(
        "dev-proven", "Proven Phone", "tok-proven",
        device_pubkey="pk-p", pubkey_proven=True,
    )
    fetched = store.device_get_by_token_hash(store.hash_device_token("tok-proven"))
    assert fetched["pubkey_proven"] == 1


def test_pre_existing_row_migrated_pubkey_proven_defaults_zero():
    """Scenario: migration marks pre-existing unproven keys as unproven.

    A row inserted BEFORE this migration lands (no pubkey_proven column in
    the INSERT) still gets pubkey_proven=0 via the column DEFAULT — the
    ALTER TABLE default applies to every pre-existing row automatically."""
    c = store._connect()
    c.execute(
        "INSERT INTO devices(device_id, name, token_hash, device_pubkey, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("dev-legacy", "Legacy Phone", "legacy-hash", "pk-legacy", 0.0),
    )
    fetched = store.device_get_by_token_hash("legacy-hash")
    assert fetched["pubkey_proven"] == 0
    # And the sealed-box guard must treat this key as ABSENT, not usable.
    assert store.device_sealing_pubkey("dev-legacy") is None


def test_device_get_by_pubkey_round_trip():
    store.device_add("dev-bypk", "By Pubkey", "tok-bypk", device_pubkey="pk-bypk")
    fetched = store.device_get_by_pubkey("pk-bypk")
    assert fetched is not None
    assert fetched["device_id"] == "dev-bypk"


def test_device_get_by_pubkey_unknown_returns_none():
    assert store.device_get_by_pubkey("no-such-pubkey") is None


def test_device_sealing_pubkey_returns_key_only_when_proven():
    store.device_add(
        "dev-seal-proven", "Sealed OK", "tok-seal-proven",
        device_pubkey="pk-seal", pubkey_proven=True,
    )
    store.device_add(
        "dev-seal-unproven", "Sealed No", "tok-seal-unproven",
        device_pubkey="pk-seal-2", pubkey_proven=False,
    )
    assert store.device_sealing_pubkey("dev-seal-proven") == "pk-seal"
    assert store.device_sealing_pubkey("dev-seal-unproven") is None


def test_migrate_devices_pubkey_proven_alters_a_pre_change_table():
    """Exercise the ACTUAL `ALTER TABLE` branch — the one that runs on the
    owner's real machine, not the `CREATE TABLE IF NOT EXISTS` shortcut every
    other test takes for granted (fresh test DBs are already migrated, so
    that branch never executes in the suite otherwise).

    Rebuilds `devices` with the EXACT pre-change DDL (no `pubkey_proven`),
    inserts a row representing an already-paired device (the owner's Pixel,
    paired before this change shipped), then runs the migration against it.
    """
    c = store._connect()
    # `fresh_db` already ran init_db(), so `devices` currently has the NEW
    # column. Rebuild it exactly as `_create_devices_table` looked BEFORE
    # this change, to force the migration down its real, untested path.
    c.execute("DROP TABLE devices")
    c.execute(
        """
        CREATE TABLE devices (
            device_id      TEXT PRIMARY KEY,
            name           TEXT NOT NULL,
            token_hash     TEXT NOT NULL UNIQUE,
            device_pubkey  TEXT,
            created_at     REAL NOT NULL,
            last_seen_at   REAL,
            revoked_at     REAL
        )
        """
    )
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_devices_token_hash ON devices(token_hash)"
    )
    raw_token = "already-paired-pixel-token"
    token_hash = store.hash_device_token(raw_token)
    c.execute(
        "INSERT INTO devices(device_id, name, token_hash, device_pubkey, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("dev-pixel-legacy", "Héctor's Pixel", token_hash, "pk-pixel-legacy", 1000.0),
    )
    columns_before = {r[1] for r in c.execute("PRAGMA table_info(devices)").fetchall()}
    assert "pubkey_proven" not in columns_before  # sanity: genuinely pre-change

    store.migrate_devices_pubkey_proven()

    columns_after = {r[1] for r in c.execute("PRAGMA table_info(devices)").fetchall()}
    assert "pubkey_proven" in columns_after

    fetched = store.device_get_by_token_hash(token_hash)
    assert fetched is not None
    # The pre-existing row SURVIVED with its data intact.
    assert fetched["device_id"] == "dev-pixel-legacy"
    assert fetched["name"] == "Héctor's Pixel"
    assert fetched["device_pubkey"] == "pk-pixel-legacy"
    assert fetched["created_at"] == 1000.0
    assert fetched["revoked_at"] is None
    # And it is recorded UNPROVEN — it never went through PoP.
    assert fetched["pubkey_proven"] == 0

    # Idempotent: calling it again on an already-migrated table is a no-op,
    # not an error (ALTER TABLE ADD COLUMN on an existing column would raise).
    store.migrate_devices_pubkey_proven()
    fetched_again = store.device_get_by_token_hash(token_hash)
    assert fetched_again["pubkey_proven"] == 0
    assert fetched_again["device_id"] == "dev-pixel-legacy"


def test_legacy_device_still_authenticates_after_migration(monkeypatch):
    """The migration must never lock out an already-paired device: its
    bearer token keeps working through `api_auth.BearerAuthMiddleware`
    exactly as before, even though its row predates `pubkey_proven`."""
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from axi import config
    from axi.api_auth import install_auth_middleware

    c = store._connect()
    c.execute("DROP TABLE devices")
    c.execute(
        """
        CREATE TABLE devices (
            device_id      TEXT PRIMARY KEY,
            name           TEXT NOT NULL,
            token_hash     TEXT NOT NULL UNIQUE,
            device_pubkey  TEXT,
            created_at     REAL NOT NULL,
            last_seen_at   REAL,
            revoked_at     REAL
        )
        """
    )
    raw_token = "legacy-pixel-bearer-token"
    token_hash = store.hash_device_token(raw_token)
    c.execute(
        "INSERT INTO devices(device_id, name, token_hash, device_pubkey, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("dev-pixel-auth", "Legacy Pixel", token_hash, "pk-pixel-auth", 1000.0),
    )

    store.migrate_devices_pubkey_proven()

    app = FastAPI()

    @app.get("/api/v1/whoami")
    def whoami():
        return {"ok": True}

    install_auth_middleware(app)
    config.save({"api_auth_enabled": True})
    client = TestClient(app, client=("203.0.113.5", 51000))  # non-loopback

    r = client.get("/api/v1/whoami", headers={"Authorization": f"Bearer {raw_token}"})
    assert r.status_code == 200
    assert r.json() == {"ok": True}


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
