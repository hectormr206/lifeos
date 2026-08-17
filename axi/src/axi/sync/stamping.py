"""The Lamport clock and the origin stamp: making LWW real instead of aspirational.

`nodes.lamport` and `nodes.origin_node` have existed since the sync-schema
chain and NOTHING has ever written them. Every row in every LifeOS database
carries `lamport = 0` and `origin_node = NULL`. A merge engine fed rows that
all claim clock 0 cannot order anything — it would resolve every real conflict
by whatever happened to arrive last, which is precisely the silent data loss
the design exists to prevent.

This module starts the clock, stamps every write, and backfills the rows that
were written before any of it existed.

ON THE BACKFILL BEING TRUTHFUL. Pre-existing rows keep `lamport = 0`. Inventing
a plausible-looking value for them would be a lie the merge engine then trusts;
0 says "older than anything written since the clock started", which is exactly
what they are. What they DO get is an origin, because they were authored here.
"""

from __future__ import annotations

import threading
from typing import Any

from axi import store

#: Where this device's identity is cached. Read once per process: a Lamport
#: stamp on every insert must not cost a query.
_ORIGIN_LOCK = threading.Lock()
_ORIGIN: str | None = None

#: The monotonic counter. Guarded because axi writes from several threads (the
#: daemon, the dashboard, background jobs) and two writes sharing a Lamport
#: value would make them unorderable — the tiebreak would then decide conflicts
#: it was never meant to see.
_CLOCK_LOCK = threading.Lock()
_CLOCK: int | None = None


class ParityLost(RuntimeError):
    """The migration's before/after row counts disagree. Nothing may proceed."""


def local_origin(conn=None) -> str:
    """This device's UUID, as written into `origin_node`.

    Created on first use and stored in `meta`, so it survives restarts: a
    device whose origin changed would look like a different author for
    everything it wrote afterwards, and its own rows would start conflicting
    with each other.
    """
    global _ORIGIN
    with _ORIGIN_LOCK:
        if _ORIGIN is not None:
            return _ORIGIN

        c = conn or store._connect()  # noqa: SLF001
        row = c.execute(
            "SELECT value FROM meta WHERE key = 'sync_origin_node'"
        ).fetchone()
        if row is None:
            from axi.sync import identity

            origin = identity.new_device_uuid()
            c.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES ('sync_origin_node', ?)",
                (origin,),
            )
            c.commit()
        else:
            origin = row["value"]

        _ORIGIN = origin
        return origin


def reset_cache() -> None:
    """Drop the cached origin and clock. For tests that swap databases."""
    global _ORIGIN, _CLOCK
    with _ORIGIN_LOCK:
        _ORIGIN = None
    with _CLOCK_LOCK:
        _CLOCK = None


def next_lamport(conn=None) -> int:
    """The next clock value for a local write. Strictly increasing, never repeated."""
    global _CLOCK
    with _CLOCK_LOCK:
        if _CLOCK is None:
            c = conn or store._connect()  # noqa: SLF001
            highest = 0
            for table in ("nodes", "edges"):
                row = c.execute(f"SELECT MAX(lamport) AS m FROM {table}").fetchone()
                if row and row["m"] is not None:
                    highest = max(highest, int(row["m"]))
            _CLOCK = highest
        _CLOCK += 1
        return _CLOCK


def observe_lamport(value: int) -> None:
    """Merge a peer's clock into ours.

    Lamport's rule: on receiving an event, the local clock becomes
    `max(local, received)`. Without this, a device that has been quiet would
    keep stamping low values and its genuinely newer edits would lose every
    conflict against a chattier peer.
    """
    global _CLOCK
    with _CLOCK_LOCK:
        if _CLOCK is None or value > _CLOCK:
            _CLOCK = value


# --------------------------------------------------------------------------
# migration
# --------------------------------------------------------------------------

_PARITY_TABLES = ("nodes", "edges")


def parity_reference(conn) -> dict[str, Any]:
    """Snapshot what the database holds BEFORE the migration touches it.

    Same discipline the schema-rebuild migration used: a migration that cannot
    state what it started with cannot prove it lost nothing.
    """
    reference: dict[str, Any] = {}
    for table in _PARITY_TABLES:
        row = conn.execute(
            f"SELECT COUNT(*) AS n, MAX(rowid) AS m FROM {table}"
        ).fetchone()
        reference[table] = {"count": row["n"], "max_rowid": row["m"]}
    return reference


def verify_parity(conn, reference: dict[str, Any]) -> None:
    """Raise [ParityLost] if any row went missing. Must be able to FAIL."""
    current = parity_reference(conn)
    for table, before in reference.items():
        after = current[table]
        if after["count"] < before["count"]:
            raise ParityLost(
                f"{table}: {before['count']} rows before the migration, "
                f"{after['count']} after — refusing to continue"
            )


def backfill(conn=None) -> dict[str, Any]:
    """Give pre-clock rows an origin, and start the counter above them.

    Idempotent: runs at every startup. Only rows with a NULL `origin_node` are
    touched, so a row synced FROM another device keeps that device as its
    author — overwriting it would make every device claim authorship of
    everything it ever received, and the deterministic tiebreak would stop
    meaning anything.
    """
    c = conn or store._connect()  # noqa: SLF001
    reference = parity_reference(c)
    origin = local_origin(c)

    for table in _PARITY_TABLES:
        c.execute(
            f"UPDATE {table} SET origin_node = ? WHERE origin_node IS NULL",
            (origin,),
        )
    c.commit()

    verify_parity(c, reference)

    # Reset so the counter re-reads MAX(lamport) including anything the
    # backfill saw; a stale cached counter would restart under existing rows.
    global _CLOCK
    with _CLOCK_LOCK:
        _CLOCK = None

    return reference


def ensure_sync_tables(conn=None) -> None:
    """Bookkeeping the sync engine needs, created alongside the backfill."""
    c = conn or store._connect()  # noqa: SLF001
    c.executescript(
        """
        -- How far we have got with each peer, so a push sends only what is new.
        CREATE TABLE IF NOT EXISTS sync_peer_state (
            peer_uuid   TEXT PRIMARY KEY,
            cursor      INTEGER NOT NULL DEFAULT -1,
            updated_at  REAL NOT NULL
        );

        -- Envelopes already applied. The relay guarantees at-least-once
        -- delivery, never exactly-once, so idempotency has to live here: the
        -- same envelope arriving twice must be a no-op, not a double apply.
        CREATE TABLE IF NOT EXISTS sync_applied (
            env_id     TEXT PRIMARY KEY,
            applied_at REAL NOT NULL
        );

        -- Every revision that LOST a merge. Created at startup, not on the
        -- first conflict: a table that springs into existence the moment
        -- something goes wrong is a table whose absence reads as "no conflicts"
        -- and whose queries fail on a healthy device.
        --
        -- The UNIQUE key is what stops a redelivered envelope from making the
        -- user stare at the same decision twice.
        CREATE TABLE IF NOT EXISTS sync_conflicts (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid           TEXT NOT NULL,
            losing_lamport INTEGER NOT NULL,
            losing_origin  TEXT,
            losing_payload TEXT NOT NULL,
            resolved_at    REAL NOT NULL,
            UNIQUE(uuid, losing_lamport, losing_origin, losing_payload)
        );
        """
    )
    c.commit()


def remember_applied(conn, env_id: str) -> bool:
    """Record an envelope as applied. False when it had already been seen."""
    import time

    ensure_sync_tables(conn)
    cur = conn.execute(
        "INSERT OR IGNORE INTO sync_applied(env_id, applied_at) VALUES (?, ?)",
        (env_id, time.time()),
    )
    conn.commit()
    return cur.rowcount == 1
