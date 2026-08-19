"""Deciding what to send, and knowing when it arrived.

THE CURSOR IS THE WHOLE FILE. `sync_peer_state.cursor` records the highest
Lamport value a peer has confirmed applying. Everything above it gets re-sent.

Two properties, both of which are the difference between "eventually correct"
and "silently lossy":

  * IT STARTS AT -1, NOT 0. Every row that existed before the clock started
    carries `lamport = 0` (see `stamping.backfill` — that value is truthful,
    not a placeholder). A cursor starting at 0 would treat all of them as
    already delivered, and a new device would receive a graph missing
    everything its peer had written before sync existed. -1 includes them.

  * IT ADVANCES ONLY ON THE PEER'S ECHO, never on a successful deposit. The
    relay accepting an envelope means it holds bytes, not that anyone applied
    them. An envelope that expires unacked after 30 days is then simply re-sent
    on the next pass, because the cursor never moved. Advancing on deposit
    would turn a month offline into permanent, invisible data loss.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from axi.sync import stamping

#: Below every possible Lamport value, including the 0 that backfilled rows
#: legitimately carry.
CURSOR_UNSYNCED = -1


@dataclass(frozen=True)
class ChangeSet:
    rows: list[dict[str, Any]]
    edges: list[dict[str, Any]]
    high_water: int

    def is_empty(self) -> bool:
        return not self.rows and not self.edges


def peer_cursor(conn, peer_uuid: str) -> int:
    stamping.ensure_sync_tables(conn)
    row = conn.execute(
        "SELECT cursor FROM sync_peer_state WHERE peer_uuid = ?", (peer_uuid,)
    ).fetchone()
    return CURSOR_UNSYNCED if row is None else int(row["cursor"])


def record_echo(conn, peer_uuid: str, applied_lamport: int) -> None:
    """Advance the cursor because the PEER said it applied up to here.

    Never called from the deposit path. That separation is the guarantee that a
    lost envelope costs a round trip instead of a fact.
    """
    stamping.ensure_sync_tables(conn)
    current = peer_cursor(conn, peer_uuid)
    if applied_lamport <= current:
        return  # echoes may arrive out of order; the cursor only moves forward
    conn.execute(
        "INSERT INTO sync_peer_state(peer_uuid, cursor, updated_at) VALUES (?, ?, ?)"
        " ON CONFLICT(peer_uuid) DO UPDATE SET cursor = excluded.cursor,"
        " updated_at = excluded.updated_at",
        (peer_uuid, applied_lamport, time.time()),
    )
    conn.commit()


def changes_for(conn, peer_uuid: str, *, limit: int = 500) -> ChangeSet:
    """Everything this peer has not confirmed, oldest first.

    Bounded by `limit` so one pass cannot try to seal a whole graph into a
    single envelope and hit the relay's 1 MiB ceiling. The cursor makes the
    truncation safe: whatever does not fit is simply included next pass,
    because nothing advances until the peer echoes.
    """
    cursor = peer_cursor(conn, peer_uuid)

    rows = [
        dict(r)
        for r in conn.execute(
            "SELECT uuid, kind, label, data, lamport, origin_node, deleted_at,"
            " created_at, updated_at FROM nodes WHERE lamport > ?"
            " ORDER BY lamport ASC LIMIT ?",
            (cursor, limit),
        )
    ]
    edges = [
        dict(r)
        for r in conn.execute(
            "SELECT uuid, src_uuid, dst_uuid, relation, data, lamport, origin_node,"
            " deleted_at, created_at, updated_at FROM edges WHERE lamport > ?"
            " ORDER BY lamport ASC LIMIT ?",
            (cursor, limit),
        )
    ]

    high = max(
        [int(r["lamport"] or 0) for r in rows] + [int(e["lamport"] or 0) for e in edges]
        or [cursor]
    )
    return ChangeSet(rows=rows, edges=edges, high_water=high)


def build_payload(change_set: ChangeSet, *, origin: str, echo: int) -> dict[str, Any]:
    """What travels inside a sealed envelope.

    `peer_cursor_echo` is this device telling the OTHER one how far it has
    applied — the same mechanism in reverse. Piggybacking it on the payload
    means a device that only ever receives still advances its peer's cursor,
    with no extra round trip and nothing extra for the relay to see.
    """
    return {
        "schema_version": 1,
        "origin_device": origin,
        "peer_cursor_echo": echo,
        "rows": {"nodes": change_set.rows, "edges": change_set.edges},
    }
