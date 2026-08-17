"""Slice 3a: every write stamps its Lamport clock and its origin.

WHY THIS MATTERS MORE THAN IT LOOKS. `lamport` and `origin_node` have existed
as columns since the sync-schema chain, and NOTHING has ever written them —
every row in every LifeOS database has `lamport = 0` and `origin_node = NULL`.
Last-writer-wins is therefore a schema aspiration, not behaviour.

A merge engine fed rows that all claim clock 0 cannot order anything. It would
resolve every real conflict by whatever arrived last over the network, which is
exactly the silent data loss the design set out to avoid. So the stamping has
to be in place, on EVERY write path, before a single envelope is exchanged.

The second half is the backfill: rows that already exist on a real device.
Héctor's laptop has 88 nodes and 277 edges written before any of this existed.
They get the local device's origin and keep `lamport = 0`, which is truthful —
they were written before the clock started — and the counter starts above them.
"""

from __future__ import annotations

import pytest

from axi import store
from axi.sync import stamping


def _rows(conn, table):
    return conn.execute(
        f"SELECT id, uuid, lamport, origin_node FROM {table} ORDER BY id"
    ).fetchall()


def test_a_new_node_is_stamped_with_a_clock_and_an_origin(fresh_db):
    node_id = store.add_node("fact", "desayuno")

    conn = store._connect()  # noqa: SLF001
    row = conn.execute(
        "SELECT lamport, origin_node FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()

    assert row["lamport"] > 0, "a written node must carry a real clock, not 0"
    assert row["origin_node"] is not None
    assert row["origin_node"] == stamping.local_origin()


def test_the_clock_advances_and_never_repeats(fresh_db):
    """Lamport ordering is worthless if two local writes share a value.

    Two nodes written in the same second must still be orderable — a clock that
    ties on a fast machine makes the tiebreak carry conflicts it was never
    meant to decide.
    """
    ids = [store.add_node("fact", f"n{i}") for i in range(25)]

    conn = store._connect()  # noqa: SLF001
    clocks = [
        conn.execute("SELECT lamport FROM nodes WHERE id = ?", (i,)).fetchone()["lamport"]
        for i in ids
    ]

    assert clocks == sorted(clocks)
    assert len(set(clocks)) == len(clocks), "two local writes shared a Lamport value"


def test_an_edge_is_stamped_too(fresh_db):
    a = store.add_node("fact", "uno")
    b = store.add_node("fact", "dos")
    store.add_edge(a, b, "same-day")

    conn = store._connect()  # noqa: SLF001
    row = conn.execute(
        "SELECT lamport, origin_node FROM edges ORDER BY id DESC LIMIT 1"
    ).fetchone()

    assert row["lamport"] > 0
    assert row["origin_node"] == stamping.local_origin()


def test_a_tombstone_advances_the_clock(fresh_db):
    """A delete is a change, and the merge engine has to order it against edits.

    If deleting left the clock where it was, a concurrent edit elsewhere would
    look newer than a delete that actually happened after it.
    """
    node_id = store.add_node("fact", "efímero")
    conn = store._connect()  # noqa: SLF001
    before = conn.execute(
        "SELECT lamport FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()["lamport"]

    store.delete_node(node_id)

    after = conn.execute(
        "SELECT lamport FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()["lamport"]
    assert after > before


# --------------------------------------------------------------------------
# the backfill, against rows that predate all of this
# --------------------------------------------------------------------------


def _write_legacy_rows(conn, count=5):
    """Rows exactly as a pre-sync LifeOS wrote them: no clock, no origin."""
    import time
    import uuid as _uuid

    now = time.time()
    for i in range(count):
        conn.execute(
            "INSERT INTO nodes(kind, label, data, created_at, updated_at, uuid,"
            " lamport, origin_node) VALUES (?, ?, '{}', ?, ?, ?, 0, NULL)",
            ("fact", f"viejo {i}", now, now, str(_uuid.uuid4())),
        )
    conn.commit()


def test_the_backfill_captures_a_parity_reference_before_touching_anything(fresh_db):
    """3a.1 — the same discipline the schema-rebuild migration used.

    A migration that cannot say what the database looked like beforehand cannot
    prove it did not lose anything. The reference is captured first, or the
    migration does not run.
    """
    conn = store._connect()  # noqa: SLF001
    _write_legacy_rows(conn, count=5)

    reference = stamping.parity_reference(conn)

    assert reference["nodes"]["count"] == 5
    assert reference["nodes"]["max_rowid"] is not None
    assert "edges" in reference


def test_the_backfill_stamps_an_origin_and_leaves_the_clock_at_zero(fresh_db):
    """3a.2 — truthful, not flattering.

    These rows really were written before the clock existed. Inventing a
    plausible-looking Lamport value for them would be a lie the merge engine
    would then trust; 0 says "older than anything this device has written
    since", which is exactly right.
    """
    conn = store._connect()  # noqa: SLF001
    _write_legacy_rows(conn, count=5)

    stamping.backfill(conn)

    for row in _rows(conn, "nodes"):
        assert row["origin_node"] == stamping.local_origin()
        assert row["lamport"] == 0


def test_the_counter_starts_above_every_existing_row(fresh_db):
    conn = store._connect()  # noqa: SLF001
    conn.execute(
        "INSERT INTO nodes(kind, label, data, created_at, updated_at, uuid,"
        " lamport, origin_node) VALUES ('fact','alto','{}',0,0,'u-alto', 41, NULL)"
    )
    conn.commit()

    stamping.backfill(conn)
    node_id = store.add_node("fact", "nuevo")

    row = conn.execute(
        "SELECT lamport FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()
    assert row["lamport"] > 41, "the counter must not restart under existing rows"


def test_the_backfill_is_idempotent(fresh_db):
    """3a.3 — it runs at every startup; re-running must change nothing."""
    conn = store._connect()  # noqa: SLF001
    _write_legacy_rows(conn, count=4)

    stamping.backfill(conn)
    first = [dict(r) for r in _rows(conn, "nodes")]

    stamping.backfill(conn)
    second = [dict(r) for r in _rows(conn, "nodes")]

    assert first == second


def test_the_backfill_never_overwrites_a_row_that_already_has_an_origin(fresh_db):
    """A row synced FROM another device must keep that device as its origin.

    Overwriting it with the local uuid would make every device claim authorship
    of everything it ever received, and `origin_node` — the deterministic
    tiebreak — would stop meaning anything.
    """
    conn = store._connect()  # noqa: SLF001
    conn.execute(
        "INSERT INTO nodes(kind, label, data, created_at, updated_at, uuid,"
        " lamport, origin_node) VALUES ('fact','ajeno','{}',0,0,'u-ajeno', 7, 'otro-dispositivo')"
    )
    conn.commit()

    stamping.backfill(conn)

    row = conn.execute(
        "SELECT lamport, origin_node FROM nodes WHERE uuid = 'u-ajeno'"
    ).fetchone()
    assert row["origin_node"] == "otro-dispositivo"
    assert row["lamport"] == 7


def test_the_backfill_preserves_every_row_it_touched(fresh_db):
    """The parity check the reference exists for: same rows in, same rows out."""
    conn = store._connect()  # noqa: SLF001
    _write_legacy_rows(conn, count=6)
    before = stamping.parity_reference(conn)

    stamping.backfill(conn)

    after = stamping.parity_reference(conn)
    assert after["nodes"]["count"] == before["nodes"]["count"]
    assert after["nodes"]["max_rowid"] == before["nodes"]["max_rowid"]


def test_verify_refuses_to_pass_when_rows_went_missing(fresh_db):
    """The check must be able to FAIL, or it proves nothing.

    A verification that cannot detect the loss it exists to detect is worse
    than none: it produces confidence without evidence.
    """
    conn = store._connect()  # noqa: SLF001
    _write_legacy_rows(conn, count=6)
    before = stamping.parity_reference(conn)

    conn.execute("DELETE FROM nodes WHERE id = (SELECT MIN(id) FROM nodes)")
    conn.commit()

    with pytest.raises(stamping.ParityLost):
        stamping.verify_parity(conn, before)


# --------------------------------------------------------------------------
# the sync bookkeeping tables
# --------------------------------------------------------------------------


def test_the_sync_bookkeeping_tables_exist(fresh_db):
    """3a.6 — `sync_peer_state` and `sync_applied` DDL.

    `sync_applied` is what makes applying the same envelope twice a no-op; the
    relay guarantees at-least-once delivery, never exactly-once, so idempotency
    has to live here.
    """
    conn = store._connect()  # noqa: SLF001
    tables = {
        r["name"]
        for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }

    assert "sync_peer_state" in tables
    assert "sync_applied" in tables


def test_applying_the_same_envelope_twice_is_recorded_once(fresh_db):
    conn = store._connect()  # noqa: SLF001

    assert stamping.remember_applied(conn, "env-1") is True
    assert stamping.remember_applied(conn, "env-1") is False
