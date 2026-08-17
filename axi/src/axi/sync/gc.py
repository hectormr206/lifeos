"""Reclaiming space from tombstones, without resurrecting a deletion.

Every delete in LifeOS leaves a tombstone: the row stays, marked `deleted_at`.
That is deliberate, not sloppy — a tombstone is how a delete TRAVELS. Hard-delete
the row and the other device never learns about it, then cheerfully sends the
record back on the next sync. The user watches something they erased reappear
and has no way to know why.

So the database grew forever and nobody owned the cleanup. This is it.

THE RULE THAT MAKES PURGING SAFE. A tombstone may only go once EVERY peer has
confirmed applying a Lamport value at or above it. `sync_peer_state.cursor`
records exactly that, which is why this could not be written before the sync
engine existed: there was no way to know what the other device had seen.

The slowest peer therefore holds back the whole purge, and that is correct.
Deleting on the majority's behalf resurrects the record on the one device that
never heard — the precise failure this guard exists for. Disk is cheap; a
memory the user deleted coming back is not.
"""

from __future__ import annotations

import time

from axi.sync import stamping

#: Below this, refuse. A caller passing 0 "to clean everything" would purge
#: tombstones written seconds ago, before any peer could possibly have synced.
MIN_GRACE_DAYS = 1


def _slowest_peer_cursor(conn) -> int | None:
    """The lowest cursor across all known peers, or None when there are none.

    None means "single device": nothing can be resurrected by a peer that does
    not exist, so age alone decides.
    """
    stamping.ensure_sync_tables(conn)
    row = conn.execute("SELECT MIN(cursor) AS m FROM sync_peer_state").fetchone()
    return None if row is None or row["m"] is None else int(row["m"])


def purge_tombstones(conn, *, older_than_days: float = 90) -> int:
    """Delete tombstones that are old AND that every peer has already applied.

    Returns how many rows went, so a caller can log it. A GC that runs silently
    is a GC nobody can audit after the fact — and the first question after an
    unexplained gap in someone's data is always "did something delete it?".
    """
    if older_than_days < MIN_GRACE_DAYS:
        raise ValueError(
            f"the tombstone grace period must be at least {MIN_GRACE_DAYS} day(s); "
            f"got {older_than_days}. Purging fresh tombstones resurrects "
            f"deletions on every peer that has not synced yet."
        )

    cutoff = time.time() - older_than_days * 86400
    slowest = _slowest_peer_cursor(conn)

    purged = 0
    for table in ("nodes", "edges"):
        if slowest is None:
            cur = conn.execute(
                f"DELETE FROM {table} WHERE deleted_at IS NOT NULL AND deleted_at <= ?",
                (cutoff,),
            )
        else:
            # `lamport <= slowest`: the peer has confirmed applying at least
            # this far, so it already knows about the delete and will never
            # send the record back.
            cur = conn.execute(
                f"DELETE FROM {table} WHERE deleted_at IS NOT NULL"
                f" AND deleted_at <= ? AND lamport <= ?",
                (cutoff, slowest),
            )
        purged += cur.rowcount
    conn.commit()
    return purged
