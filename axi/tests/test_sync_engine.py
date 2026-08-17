"""Slice 3c: sealing change sets, and the cursor that decides what to re-send.

The cursor rules here are the difference between "eventually correct" and
"silently lossy", and both failure modes are invisible from the app:

  * A cursor starting at 0 skips every row written before the clock existed —
    a new device receives a graph with a hole in it and nothing reports it.
  * A cursor advancing on DEPOSIT rather than on the peer's echo turns a month
    offline into permanent loss: the envelope expires at the relay, the sender
    believes it delivered, and nobody ever re-sends.
"""

from __future__ import annotations

import os

import pytest

from axi import store
from axi.sync import engine, envelope, merge, stamping

PEER = "cccc2222"


def test_an_envelope_round_trips(fresh_db):
    """3c.1"""
    data_key = os.urandom(32)
    recipient = os.urandom(16).hex()
    payload = {"schema_version": 1, "rows": {"nodes": [{"uuid": "u-1"}], "edges": []}}

    blob = envelope.seal(data_key=data_key, recipient_uuid=recipient, payload=payload)
    opened = envelope.open_envelope(data_key=data_key, blob=blob)

    assert opened.recipient == recipient
    assert opened.payload == payload
    assert len(opened.env_id) == 64


def test_the_header_is_opaque_apart_from_routing(fresh_db):
    """Everything past byte 49 must be indistinguishable from noise."""
    data_key = os.urandom(32)
    recipient = os.urandom(16).hex()

    blob = envelope.seal(
        data_key=data_key,
        recipient_uuid=recipient,
        payload={"secreto": "hipertensión diagnosticada"},
    )

    assert blob[0] == envelope.VERSION
    assert blob[33:49].hex() == recipient
    assert b"hipertension" not in blob
    assert b"secreto" not in blob


def test_a_wrong_key_cannot_open_it(fresh_db):
    blob = envelope.seal(
        data_key=os.urandom(32), recipient_uuid=os.urandom(16).hex(), payload={"a": 1}
    )

    with pytest.raises(envelope.SealError):
        envelope.open_envelope(data_key=os.urandom(32), blob=blob)


def test_re_addressing_an_envelope_breaks_it(fresh_db):
    """The header is authenticated: a relay that reroutes produces a failure,
    never a change applied to the wrong graph."""
    data_key = os.urandom(32)
    blob = bytearray(
        envelope.seal(
            data_key=data_key, recipient_uuid=os.urandom(16).hex(), payload={"a": 1}
        )
    )

    blob[40] ^= 0xFF  # flip a bit inside the recipient uuid

    with pytest.raises(envelope.SealError):
        envelope.open_envelope(data_key=data_key, blob=bytes(blob))


def test_two_envelopes_never_share_an_envelope_key(fresh_db):
    """Nonce reuse is impossible by construction, so prove the construction.

    Identical payload, identical key: if the ciphertexts matched, the env_id
    would not be doing its job and the fixed nonce would be a catastrophe.
    """
    data_key = os.urandom(32)
    recipient = os.urandom(16).hex()

    a = envelope.seal(data_key=data_key, recipient_uuid=recipient, payload={"a": 1})
    b = envelope.seal(data_key=data_key, recipient_uuid=recipient, payload={"a": 1})

    assert a[1:33] != b[1:33], "two envelopes shared an env_id"
    assert a[49:] != b[49:], "identical plaintext produced identical ciphertext"


# --------------------------------------------------------------------------
# the cursor
# --------------------------------------------------------------------------


def test_a_new_peer_starts_below_zero(fresh_db):
    """3c.2 — backfilled rows carry lamport 0 and MUST be included."""
    conn = store._connect()  # noqa: SLF001

    assert engine.peer_cursor(conn, PEER) == -1


def test_the_first_sync_includes_rows_written_before_the_clock_started(fresh_db):
    """3c.2 — the hole this rule exists to prevent."""
    conn = store._connect()  # noqa: SLF001
    conn.execute(
        "INSERT INTO nodes(kind, label, data, created_at, updated_at, uuid,"
        " lamport, origin_node) VALUES ('fact','prehistórico','{}',0,0,'u-old',0,'aaaa')"
    )
    conn.commit()

    change_set = engine.changes_for(conn, PEER)

    assert [r["uuid"] for r in change_set.rows] == ["u-old"]


def test_the_cursor_does_not_move_when_an_envelope_is_merely_deposited(fresh_db):
    """3c.3 — the relay holding bytes is not the peer having applied them."""
    conn = store._connect()  # noqa: SLF001
    store.add_node("fact", "algo")

    before = engine.peer_cursor(conn, PEER)
    change_set = engine.changes_for(conn, PEER)
    envelope.seal(
        data_key=os.urandom(32),
        recipient_uuid=os.urandom(16).hex(),
        payload=engine.build_payload(change_set, origin="local", echo=-1),
    )

    assert engine.peer_cursor(conn, PEER) == before


def test_the_cursor_moves_only_on_the_peers_echo(fresh_db):
    """3c.3"""
    conn = store._connect()  # noqa: SLF001
    store.add_node("fact", "algo")
    change_set = engine.changes_for(conn, PEER)

    engine.record_echo(conn, PEER, change_set.high_water)

    assert engine.peer_cursor(conn, PEER) == change_set.high_water
    assert engine.changes_for(conn, PEER).is_empty()


def test_an_out_of_order_echo_never_rewinds_the_cursor(fresh_db):
    """Envelopes race. A late echo carrying an older value must not undo a
    newer one, or the sender would re-send data the peer already has forever."""
    conn = store._connect()  # noqa: SLF001

    engine.record_echo(conn, PEER, 50)
    engine.record_echo(conn, PEER, 20)

    assert engine.peer_cursor(conn, PEER) == 50


def test_an_expired_envelope_is_repaired_by_the_next_pass(fresh_db):
    """3c.4 — a month offline costs a round trip, never a fact.

    The envelope is deposited and then lost (expired at the relay, unacked).
    Because the cursor never moved, the very next pass includes exactly the
    same rows again. This is the property that makes the 30-day TTL safe.
    """
    conn = store._connect()  # noqa: SLF001
    store.add_node("fact", "importante")

    first = engine.changes_for(conn, PEER)
    assert len(first.rows) == 1
    # ...envelope deposited, never acked, swept 30 days later. No echo.

    second = engine.changes_for(conn, PEER)
    assert [r["uuid"] for r in second.rows] == [r["uuid"] for r in first.rows]


def test_a_full_two_store_round_trip(fresh_db):
    """The whole slice end to end, against the real merge engine."""
    conn = store._connect()  # noqa: SLF001
    data_key = os.urandom(32)
    recipient = os.urandom(16).hex()

    node_id = store.add_node("fact", "viaja entre dispositivos")
    original_uuid = conn.execute(
        "SELECT uuid FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()["uuid"]

    change_set = engine.changes_for(conn, PEER)
    blob = envelope.seal(
        data_key=data_key,
        recipient_uuid=recipient,
        payload=engine.build_payload(change_set, origin="local", echo=-1),
    )

    # ...arrives at the peer, which opens it and merges. Simulated here by
    # deleting the row and re-applying, which is what a fresh device sees.
    opened = envelope.open_envelope(data_key=data_key, blob=blob)
    conn.execute("DELETE FROM nodes WHERE uuid = ?", (original_uuid,))
    conn.commit()

    result = merge.apply_envelope(
        conn,
        env_id=opened.env_id,
        rows=opened.payload["rows"]["nodes"],
        edges=opened.payload["rows"]["edges"],
    )

    assert result.applied is True
    row = conn.execute(
        "SELECT label FROM nodes WHERE uuid = ?", (original_uuid,)
    ).fetchone()
    assert row["label"] == "viaja entre dispositivos"


def test_a_change_set_is_bounded_so_one_envelope_cannot_overflow_the_relay(fresh_db):
    """The relay refuses anything over 1 MiB; truncation must be safe.

    It is, because nothing advances until the peer echoes: whatever did not fit
    is simply included in the next pass.
    """
    conn = store._connect()  # noqa: SLF001
    for i in range(30):
        store.add_node("fact", f"n{i}")

    change_set = engine.changes_for(conn, PEER, limit=10)

    assert len(change_set.rows) == 10
    assert engine.peer_cursor(conn, PEER) == -1
