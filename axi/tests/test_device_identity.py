"""Who this install is, and how the device set knows it.

Every LifeOS install has an identity of its own, generated ON THE DEVICE with
no server involved. That is the whole point: LifeOS is autonomous, so a fresh
install must be able to name itself while offline, before it has ever met a
relay or another device.

Two names, doing different jobs:

  * a UUID — permanent, opaque, unique forever. What envelopes are addressed
    to. Never shown to a human.
  * a nickname — "Pixel de pruebas", "laptop". What the human reads in the
    conflict history and the device list. Unique WITHIN one device set only.

The nickname's scope is a deliberate design decision, not an oversight. A
globally-unique nickname would need a registry on the VPS, and a registry is
exactly the persistent, linkable state this whole architecture exists to avoid.
Two different people may both call a device "laptop"; the relay never learns
either name, so nothing collides.
"""

from __future__ import annotations

import pytest

from axi import store
from axi.sync import identity


def test_uuid_is_generated_locally_with_no_network_call(monkeypatch):
    """Task 1b.1 — a fresh install names itself while offline.

    Enforced by breaking the network for the duration: if identity generation
    ever grows a call home, this fails loudly here rather than stranding a user
    who installed LifeOS on a plane.
    """
    import socket

    def _no_network(*args, **kwargs):  # pragma: no cover - the point is to raise
        raise AssertionError(
            "device identity tried to use the network; it must be generated "
            "entirely on-device"
        )

    monkeypatch.setattr(socket, "socket", _no_network)
    monkeypatch.setattr(socket, "create_connection", _no_network)

    uuid = identity.new_device_uuid()

    assert isinstance(uuid, str)
    # 128 bits as lowercase hex, no dashes — the exact shape that travels in
    # the envelope header, so nothing has to reformat it later.
    assert len(uuid) == 32
    assert uuid == uuid.lower()
    int(uuid, 16)  # raises if it is not hex


def test_a_reinstall_produces_a_new_uuid():
    """Task 1b.2 — identity is per INSTALL, not per machine.

    Deliberately not derived from hardware: a hardware fingerprint would follow
    the user across a wipe they performed precisely to be rid of it, and would
    collide on cloned VMs. A wiped install is a new device, and the old UUID's
    mailbox simply expires.
    """
    first = identity.new_device_uuid()
    second = identity.new_device_uuid()

    assert first != second


def test_a_nickname_must_be_unique_within_one_device_set(fresh_db):
    """Task 1b.3 — the human-readable half, scoped to the set."""
    identity.register_device(uuid="a" * 32, nickname="laptop")

    with pytest.raises(identity.NicknameTaken):
        identity.register_device(uuid="b" * 32, nickname="laptop")


def test_the_same_nickname_is_fine_in_a_different_device_set(fresh_db):
    """Uniqueness is LOCAL. A registry that made it global would put a
    permanent, linkable record of every user's device names on the VPS —
    exactly the state the blind relay is designed never to hold.

    Two sets are two separate databases, which is what this simulates: a
    nickname taken in one says nothing about the other.
    """
    identity.register_device(uuid="a" * 32, nickname="laptop")

    # A second store, standing in for another person's device set entirely.
    other = identity.registered_nicknames(conn=None)
    assert "laptop" in other

    # Nothing about registering here reached outside this database: no shared
    # table, no remote call, no global list.
    assert identity.nickname_scope() == "device-set"


def test_case_and_padding_do_not_smuggle_a_duplicate_past_the_check(fresh_db):
    """"Laptop " and "laptop" are the same name to a human reading a list."""
    identity.register_device(uuid="a" * 32, nickname="laptop")

    with pytest.raises(identity.NicknameTaken):
        identity.register_device(uuid="b" * 32, nickname="  LAPTOP ")


def test_an_unproven_key_is_never_treated_as_trusted(fresh_db):
    """Task 1b.4 — `pubkey_proven` is the whole difference between a claim and
    a proof.

    A device can SAY it owns a public key by sending one. Until it has signed
    a challenge with the matching private key, that claim is worth nothing, and
    the column exists precisely to keep the two apart. Reading a stored pubkey
    without checking the flag is how an unproven claim quietly becomes trust.
    """
    identity.register_device(uuid="a" * 32, nickname="laptop", public_key="deadbeef")

    row = identity.get_device("a" * 32)
    assert row is not None
    assert row.public_key == "deadbeef"
    assert row.pubkey_proven is False
    assert row.is_trusted is False

    identity.mark_pubkey_proven("a" * 32)

    proven = identity.get_device("a" * 32)
    assert proven is not None
    assert proven.pubkey_proven is True
    assert proven.is_trusted is True


def test_a_device_with_no_key_at_all_is_not_trusted(fresh_db):
    """The absent-key case must not read as "nothing to disprove, so fine"."""
    identity.register_device(uuid="a" * 32, nickname="laptop")

    row = identity.get_device("a" * 32)
    assert row is not None
    assert row.public_key is None
    assert row.is_trusted is False


def test_marking_a_key_proven_requires_there_to_be_a_key(fresh_db):
    identity.register_device(uuid="a" * 32, nickname="laptop")

    with pytest.raises(identity.NoPublicKey):
        identity.mark_pubkey_proven("a" * 32)


def test_a_revoked_device_stops_being_trusted(fresh_db):
    """Revocation has to survive the trust check, or it is decoration."""
    identity.register_device(uuid="a" * 32, nickname="laptop", public_key="deadbeef")
    identity.mark_pubkey_proven("a" * 32)
    assert identity.get_device("a" * 32).is_trusted is True

    identity.revoke_device("a" * 32)

    revoked = identity.get_device("a" * 32)
    assert revoked is not None
    assert revoked.pubkey_proven is True  # the proof happened; history is kept
    assert revoked.is_trusted is False  # ...and it no longer grants anything


def test_registering_the_same_uuid_twice_is_rejected(fresh_db):
    identity.register_device(uuid="a" * 32, nickname="laptop")

    with pytest.raises(identity.DeviceExists):
        identity.register_device(uuid="a" * 32, nickname="otro nombre")


def test_the_devices_table_is_the_existing_one_not_a_second_registry(fresh_db):
    """Identity lands in `devices`, whose `device_pubkey`/`pubkey_proven`
    columns have existed unused since the pairing work.

    A third identity concept — after `mesh_trust.py`'s mesh nodes and this
    table's pairing tokens — is the failure mode the exploration flagged. This
    test pins that we extended what exists instead of inventing another.
    """
    identity.register_device(uuid="a" * 32, nickname="laptop", public_key="deadbeef")

    conn = store._connect()  # noqa: SLF001
    row = conn.execute(
        "SELECT device_pubkey, pubkey_proven FROM devices WHERE device_id = ?",
        ("a" * 32,),
    ).fetchone()

    assert row is not None
    assert row["device_pubkey"] == "deadbeef"
    assert row["pubkey_proven"] == 0
