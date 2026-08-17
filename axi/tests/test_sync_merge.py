"""The merge engine: where data gets lost if this is wrong.

Every other slice can be rebuilt from its inputs. This one decides which of two
versions of the user's memory survives, and a mistake here is silent — the app
keeps working, showing the wrong thing, and nobody can tell which write was
dropped or when.

THE RULES, in the order they are applied:

  1. Never seen locally      -> insert.
  2. Higher `lamport` wins.
  3. Equal `lamport`         -> lexicographically greater `origin_node` wins.
     Arbitrary, but DETERMINISTIC: both devices must reach the same answer
     without talking to each other, or they diverge permanently.
  4. A DELETE dominates, even against a higher `lamport`. This is the ONLY
     deviation from pure last-writer-wins, and it is deliberate — see below.
  5. The loser is never destroyed; it lands in `sync_conflicts`.

WHY DELETE DOMINATES. You delete a note on the laptop. The phone is offline and
you edit that same note there afterwards. Under pure LWW the edit has the
higher clock, so the note comes BACK. In an app holding a person's whole life,
resurrecting something the user believed erased is a privacy failure, not a
merge outcome. The losing edit is preserved in conflict history, so nothing is
actually lost — the user can restore it deliberately if the delete was the
mistake.
"""

from __future__ import annotations

import pytest

from axi import store
from axi.sync import merge

LOCAL = "aaaa0000"
PEER = "bbbb1111"


def _remote(uuid, *, label="remoto", lamport=1, origin=PEER, deleted_at=None):
    """One incoming row, as it travels inside an envelope."""
    return {
        "uuid": uuid,
        "kind": "fact",
        "label": label,
        "data": "{}",
        "lamport": lamport,
        "origin_node": origin,
        "deleted_at": deleted_at,
        "updated_at": 1000.0,
    }


def _local_row(conn, uuid):
    return conn.execute(
        "SELECT uuid, label, lamport, origin_node, deleted_at FROM nodes WHERE uuid = ?",
        (uuid,),
    ).fetchone()


def _conflicts(conn):
    return conn.execute(
        "SELECT uuid, losing_lamport, losing_origin, losing_payload FROM sync_conflicts"
    ).fetchall()


# --------------------------------------------------------------------------


def test_a_node_we_have_never_seen_is_inserted(fresh_db):
    """3b.1"""
    conn = store._connect()  # noqa: SLF001

    result = merge.apply_node(conn, _remote("u-1", label="nuevo"))

    assert result is merge.Outcome.inserted
    assert _local_row(conn, "u-1")["label"] == "nuevo"
    assert _conflicts(conn) == []


def test_a_higher_lamport_wins(fresh_db):
    """3b.2"""
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="viejo", lamport=3))

    merge.apply_node(conn, _remote("u-1", label="nuevo", lamport=9))

    assert _local_row(conn, "u-1")["label"] == "nuevo"


def test_a_lower_lamport_loses_and_is_preserved(fresh_db):
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="ganador", lamport=9))

    result = merge.apply_node(conn, _remote("u-1", label="perdedor", lamport=3))

    assert result is merge.Outcome.rejected
    assert _local_row(conn, "u-1")["label"] == "ganador"
    losers = _conflicts(conn)
    assert len(losers) == 1
    assert "perdedor" in losers[0]["losing_payload"]


def test_an_equal_lamport_is_broken_by_origin_deterministically(fresh_db):
    """3b.3 — both devices must reach the same answer without talking.

    Which origin wins is arbitrary. That it is the SAME everywhere is not: a
    non-deterministic tiebreak makes two devices disagree permanently, and
    neither can tell it happened.
    """
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="de-aaaa", lamport=5, origin="aaaa"))

    merge.apply_node(conn, _remote("u-1", label="de-zzzz", lamport=5, origin="zzzz"))

    assert _local_row(conn, "u-1")["label"] == "de-zzzz"

    # ...and the reverse order reaches the identical result.
    merge.apply_node(conn, _remote("u-1", label="de-aaaa-otra", lamport=5, origin="aaaa"))
    assert _local_row(conn, "u-1")["label"] == "de-zzzz"


def test_a_tombstone_propagates(fresh_db):
    """3b.4"""
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", lamport=1))

    merge.apply_node(conn, _remote("u-1", lamport=2, deleted_at=2000.0))

    assert _local_row(conn, "u-1")["deleted_at"] is not None


def test_a_stale_live_revision_never_resurrects_a_tombstone(fresh_db):
    """3b.4 — the LOW-clock case, which pure LWW already handles."""
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", lamport=5, deleted_at=2000.0))

    merge.apply_node(conn, _remote("u-1", label="revivido", lamport=2))

    assert _local_row(conn, "u-1")["deleted_at"] is not None


def test_delete_dominates_a_concurrent_edit_with_a_higher_lamport(fresh_db):
    """3b.5 — the ONE deviation from pure LWW, and the reason for it.

    Tombstone at clock 5, edit at clock 7. Pure LWW resurrects the note. We do
    not: in an app holding a person's whole life, handing back something they
    believed erased is a privacy failure, not a merge outcome.

    Nothing is lost — the losing edit goes to conflict history, visible, so the
    user can restore it deliberately if the delete was the mistake.
    """
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", lamport=5, deleted_at=2000.0, origin="aaaa"))

    result = merge.apply_node(
        conn, _remote("u-1", label="editado despues", lamport=7, origin="bbbb")
    )

    assert result is merge.Outcome.rejected
    row = _local_row(conn, "u-1")
    assert row["deleted_at"] is not None, "the delete must survive the higher clock"

    losers = _conflicts(conn)
    assert len(losers) == 1
    assert "editado despues" in losers[0]["losing_payload"]
    assert losers[0]["losing_lamport"] == 7


def test_a_later_delete_still_wins_over_an_earlier_edit(fresh_db):
    """Delete-dominates must not become delete-always-loses in reverse."""
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="editado", lamport=7))

    merge.apply_node(conn, _remote("u-1", lamport=9, deleted_at=3000.0))

    assert _local_row(conn, "u-1")["deleted_at"] is not None


def test_the_same_origin_overwriting_itself_is_not_a_conflict(fresh_db):
    """3b.6 — one device's own successive edits are linear history.

    Recording them as conflicts would bury the real ones under noise: the
    conflict view is only useful if everything in it is genuinely two devices
    disagreeing.
    """
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="v1", lamport=1, origin=PEER))

    merge.apply_node(conn, _remote("u-1", label="v2", lamport=2, origin=PEER))

    assert _local_row(conn, "u-1")["label"] == "v2"
    assert _conflicts(conn) == [], "a device overwriting its own row is not a conflict"


def test_applying_the_same_envelope_twice_changes_nothing(fresh_db):
    """3b.7 — the relay guarantees at-least-once, never exactly-once."""
    conn = store._connect()  # noqa: SLF001
    rows = [_remote("u-1", label="uno", lamport=4)]

    first = merge.apply_envelope(conn, env_id="env-1", rows=rows)
    second = merge.apply_envelope(conn, env_id="env-1", rows=rows)

    assert first.applied is True
    assert second.applied is False
    assert len(_conflicts(conn)) == 0


def test_a_replayed_losing_envelope_does_not_duplicate_the_conflict_row(fresh_db):
    """3b.7 — a duplicated conflict is a user staring at the same decision twice."""
    conn = store._connect()  # noqa: SLF001
    merge.apply_envelope(conn, env_id="win", rows=[_remote("u-1", label="gana", lamport=9)])

    losing = [_remote("u-1", label="pierde", lamport=3)]
    merge.apply_envelope(conn, env_id="lose", rows=losing)
    merge.apply_envelope(conn, env_id="lose", rows=losing)

    assert len(_conflicts(conn)) == 1


def test_an_edge_may_arrive_before_its_nodes(fresh_db):
    """3b.8 — legal by design; the schema comment says so and the merge honours it.

    Rejecting a dangling edge would silently drop relations whenever an
    envelope split a node from its edge, and the user's graph would quietly
    lose links with nothing reporting it.
    """
    conn = store._connect()  # noqa: SLF001

    result = merge.apply_edge(
        conn,
        {
            "uuid": "e-1",
            "src_uuid": "u-todavia-no",
            "dst_uuid": "u-tampoco",
            "relation": "same-day",
            "data": "{}",
            "lamport": 3,
            "origin_node": PEER,
            "deleted_at": None,
            "updated_at": 1000.0,
        },
    )

    assert result is merge.Outcome.inserted
    row = conn.execute("SELECT src_uuid FROM edges WHERE uuid = 'e-1'").fetchone()
    assert row["src_uuid"] == "u-todavia-no"

    # ...and once the node turns up, the edge resolves with no extra work.
    merge.apply_node(conn, _remote("u-todavia-no", label="llegó tarde"))
    joined = conn.execute(
        "SELECT n.label FROM edges e JOIN nodes n ON n.uuid = e.src_uuid"
        " WHERE e.uuid = 'e-1'"
    ).fetchone()
    assert joined["label"] == "llegó tarde"


def test_a_peers_clock_advances_our_own(fresh_db):
    """Lamport's rule: on receive, local = max(local, received).

    Without it a quiet device keeps stamping low values, and its genuinely
    newer edits lose every conflict against a chattier peer.
    """
    from axi.sync import stamping

    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", lamport=500))

    assert stamping.next_lamport(conn) > 500


def test_the_conflict_row_keeps_enough_to_restore_the_loser(fresh_db):
    """A conflict history that cannot restore the losing version is decoration."""
    conn = store._connect()  # noqa: SLF001
    merge.apply_node(conn, _remote("u-1", label="ganador", lamport=9))
    merge.apply_node(conn, _remote("u-1", label="perdedor valioso", lamport=3))

    row = _conflicts(conn)[0]
    assert row["uuid"] == "u-1"
    assert row["losing_lamport"] == 3
    assert row["losing_origin"] == PEER
    assert "perdedor valioso" in row["losing_payload"]


def test_a_row_without_a_uuid_is_refused(fresh_db):
    """Addressing is by uuid; a row without one cannot be merged with anything."""
    conn = store._connect()  # noqa: SLF001

    with pytest.raises(merge.MalformedRow):
        merge.apply_node(conn, {"kind": "fact", "label": "sin uuid", "lamport": 1})
