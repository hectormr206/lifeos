"""Purging tombstones without resurrecting what the user deleted.

THE PROBLEM. Every delete in LifeOS is a tombstone — the row stays, marked
`deleted_at`. That is not an oversight: a tombstone is how a delete TRAVELS. If
we hard-deleted the row, the other device would never learn about it and would
happily send the record back on the next sync, and the user would watch
something they erased reappear.

So the database grows forever, and nobody owned the cleanup. This is it.

THE CONSTRAINT THAT MAKES IT SAFE. A tombstone may only be purged once EVERY
peer has confirmed applying a Lamport value at or above it. That is exactly what
`sync_peer_state.cursor` records, and it is why this could not be written before
the sync engine existed — there was no way to know what the other device had
seen.

Purging one tombstone too early is not a tidy-up bug. It resurrects a deleted
memory on the next sync, silently, and the user has no way to know why.
"""

from __future__ import annotations

import time

import pytest

from axi import store
from axi.sync import engine, gc


def _tombstone(conn, uuid: str, lamport: int, *, age_days: float = 400.0) -> None:
    deleted_at = time.time() - age_days * 86400
    conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, created_at, updated_at,"
        " lamport, origin_node, deleted_at) VALUES (?, 'fact', ?, '{}', 0, 0, ?, 'aaaa', ?)",
        (uuid, f"borrado {uuid}", lamport, deleted_at),
    )
    conn.commit()


def _live(conn, uuid: str, lamport: int) -> None:
    conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, created_at, updated_at,"
        " lamport, origin_node, deleted_at) VALUES (?, 'fact', ?, '{}', 0, 0, ?, 'aaaa', NULL)",
        (uuid, f"vivo {uuid}", lamport),
    )
    conn.commit()


def _uuids(conn) -> set[str]:
    return {r["uuid"] for r in conn.execute("SELECT uuid FROM nodes")}


def test_a_live_row_is_never_touched(fresh_db):
    conn = store._connect()  # noqa: SLF001
    _live(conn, "u-vivo", 5)

    gc.purge_tombstones(conn, older_than_days=30)

    assert "u-vivo" in _uuids(conn)


def test_a_recent_tombstone_is_kept(fresh_db):
    """Grace period: a delete the user might still want to undo, and a peer
    that is merely offline for a week, both need the tombstone to survive."""
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-reciente", 5, age_days=3)

    gc.purge_tombstones(conn, older_than_days=30)

    assert "u-reciente" in _uuids(conn)


def test_an_old_tombstone_is_purged_when_no_peers_exist(fresh_db):
    """A single-device install has nobody to tell. Nothing can be resurrected
    by a peer that does not exist, so age alone is enough."""
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-viejo", 5)

    purged = gc.purge_tombstones(conn, older_than_days=30)

    assert purged == 1
    assert "u-viejo" not in _uuids(conn)


def test_a_tombstone_a_peer_has_not_seen_is_NOT_purged(fresh_db):
    """THE rule. Purging here resurrects the deletion on the next sync.

    The peer's cursor is 3; the tombstone is at 9. That device has never been
    told about the delete. Drop the tombstone and its next push sends the live
    record straight back.
    """
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-no-visto", 9)
    engine.record_echo(conn, "peer-1", 3)

    purged = gc.purge_tombstones(conn, older_than_days=30)

    assert purged == 0
    assert "u-no-visto" in _uuids(conn), (
        "purging a tombstone the peer never saw hands the user back a memory "
        "they deleted"
    )


def test_a_tombstone_every_peer_has_seen_is_purged(fresh_db):
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-visto", 4)
    engine.record_echo(conn, "peer-1", 10)
    engine.record_echo(conn, "peer-2", 7)

    purged = gc.purge_tombstones(conn, older_than_days=30)

    assert purged == 1
    assert "u-visto" not in _uuids(conn)


def test_the_SLOWEST_peer_decides(fresh_db):
    """One lagging device holds the whole purge back, and that is correct.

    Deleting on the majority's behalf would resurrect the record on the one
    device that never heard — the exact failure this guard exists for.
    """
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-1", 6)
    engine.record_echo(conn, "peer-rapido", 100)
    engine.record_echo(conn, "peer-lento", 2)

    assert gc.purge_tombstones(conn, older_than_days=30) == 0

    engine.record_echo(conn, "peer-lento", 6)
    assert gc.purge_tombstones(conn, older_than_days=30) == 1


def test_edges_are_purged_under_the_same_rule(fresh_db):
    conn = store._connect()  # noqa: SLF001
    conn.execute(
        "INSERT INTO edges(uuid, src_uuid, dst_uuid, relation, data, created_at,"
        " updated_at, lamport, origin_node, deleted_at)"
        " VALUES ('e-1','a','b','same-day','{}',0,0,4,'aaaa',?)",
        (time.time() - 400 * 86400,),
    )
    conn.commit()
    engine.record_echo(conn, "peer-1", 10)

    gc.purge_tombstones(conn, older_than_days=30)

    assert conn.execute("SELECT COUNT(*) AS n FROM edges").fetchone()["n"] == 0


def test_purging_reports_what_it_did(fresh_db):
    """A GC that runs silently is a GC nobody can audit after the fact."""
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-1", 1)
    _tombstone(conn, "u-2", 2)
    engine.record_echo(conn, "peer-1", 50)

    assert gc.purge_tombstones(conn, older_than_days=30) == 2


def test_it_is_safe_to_run_twice(fresh_db):
    conn = store._connect()  # noqa: SLF001
    _tombstone(conn, "u-1", 1)
    engine.record_echo(conn, "peer-1", 50)

    assert gc.purge_tombstones(conn, older_than_days=30) == 1
    assert gc.purge_tombstones(conn, older_than_days=30) == 0


def test_a_negative_grace_period_is_refused(fresh_db):
    """Guard against a caller passing 0 or -1 "to clean everything".

    That would purge tombstones written seconds ago, before any peer could
    possibly have synced — the resurrection bug, triggered deliberately by
    someone trying to free space.
    """
    conn = store._connect()  # noqa: SLF001

    with pytest.raises(ValueError):
        gc.purge_tombstones(conn, older_than_days=0)
