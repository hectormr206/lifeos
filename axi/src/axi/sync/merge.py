"""Deciding which version of a memory survives.

This is the file where data gets lost if it is wrong, and the loss is silent:
the app keeps working, shows the wrong thing, and nobody can tell which write
was dropped or when. Everything here is written to make the losing side
recoverable rather than to be clever.

THE RULES, in order:

  1. Never seen locally           -> insert.
  2. Higher `lamport` wins.
  3. Equal `lamport`              -> lexicographically greater `origin_node`.
  4. A DELETE dominates, even against a higher `lamport`.
  5. The loser goes to `sync_conflicts`, never to nowhere.

Rule 3 is arbitrary and that is fine; what matters is that it is DETERMINISTIC.
Both devices must reach the same answer without talking to each other, or they
diverge permanently and neither can tell.

Rule 4 is the only deviation from pure last-writer-wins. You delete a note on
the laptop; the phone is offline and you edit that note there afterwards. Pure
LWW gives the edit the higher clock and the note comes BACK. In an app holding
a person's whole life, handing back something they believed erased is a privacy
failure, not a merge outcome. Rule 5 is what makes rule 4 safe: the edit is
preserved and visible, so a delete that was itself the mistake can be undone
deliberately.
"""

from __future__ import annotations

import enum
import json
import time
from dataclasses import dataclass
from typing import Any, Iterable

from axi.sync import stamping


class MalformedRow(ValueError):
    """The incoming row cannot be merged — no uuid to address it by."""


class Outcome(enum.Enum):
    inserted = "inserted"
    updated = "updated"
    rejected = "rejected"


@dataclass(frozen=True)
class EnvelopeResult:
    applied: bool
    outcomes: tuple[Outcome, ...] = ()


def ensure_conflict_table(conn) -> None:
    """The DDL lives in `stamping.ensure_sync_tables`, which runs at startup.

    Called here too so a caller that reached the merge without going through
    `init_db` — a test, a script — still finds the table rather than a
    confusing "no such table" from deep inside a conflict path.
    """
    stamping.ensure_sync_tables(conn)


def _wins(incoming: tuple[int, str], existing: tuple[int, str]) -> bool:
    """Rules 2 and 3: compare (lamport, origin) as one ordered pair.

    Comparing the tuple rather than branching on lamport-then-origin keeps the
    tiebreak impossible to forget: there is no path through this function that
    reaches a decision without having consulted the origin.
    """
    return incoming > existing


def decide(
    *,
    local_lamport: int | None,
    local_origin: str | None,
    local_deleted: bool,
    incoming_lamport: int,
    incoming_origin: str,
    incoming_deleted: bool,
    exists_locally: bool,
) -> Outcome:
    """THE rule, as one pure function with no database in sight.

    Extracted so the Dart mirror can be a line-for-line translation of exactly
    this, and so `shared/sync-test-vectors/merge_cases.json` exercises the same
    code path both languages ship. A decision tangled into an UPDATE statement
    can only be compared across languages by reading it and hoping.

    Rule 4 is checked FIRST, before any clock comparison. Inside the comparison
    it would be one refactor of the condition order away from silently losing
    its effect.
    """
    if not exists_locally:
        return Outcome.inserted

    # RULE 4 — a live incoming revision never beats a local tombstone, however
    # high its Lamport value.
    if local_deleted and not incoming_deleted:
        return Outcome.rejected

    # RULE 4b — the MIRROR, which is not optional. Rule 4 alone protects a local
    # tombstone but leaves an INCOMING tombstone to the clock tiebreak; at equal
    # Lamport values that compares origin uuids, so one device rejects the other's
    # delete while the other rejects its edit, and they diverge for ever with
    # nothing reporting it. Delete dominates BOTH ways so both sides converge.
    if incoming_deleted and not local_deleted:
        return Outcome.updated

    if _wins(
        (incoming_lamport, incoming_origin),
        (int(local_lamport or 0), local_origin or ""),
    ):
        return Outcome.updated
    return Outcome.rejected


def _payload_of(row: dict[str, Any]) -> str:
    """What we keep of a losing revision: enough to put it back."""
    return json.dumps(
        {k: row.get(k) for k in ("uuid", "kind", "label", "data", "relation")},
        ensure_ascii=False,
        sort_keys=True,
    )


def _record_conflict(conn, row: dict[str, Any]) -> None:
    ensure_conflict_table(conn)
    # INSERT OR IGNORE against the UNIQUE key: an envelope redelivered by the
    # relay must not make the user stare at the same decision twice.
    conn.execute(
        "INSERT OR IGNORE INTO sync_conflicts"
        " (uuid, losing_lamport, losing_origin, losing_payload, resolved_at)"
        " VALUES (?, ?, ?, ?, ?)",
        (
            row["uuid"],
            int(row.get("lamport") or 0),
            row.get("origin_node"),
            _payload_of(row),
            time.time(),
        ),
    )
    conn.commit()


def _require_uuid(row: dict[str, Any]) -> str:
    value = row.get("uuid")
    if not value:
        raise MalformedRow("an incoming row has no uuid; nothing to merge it with")
    return value


def apply_node(conn, row: dict[str, Any]) -> Outcome:
    uuid = _require_uuid(row)
    incoming_clock = int(row.get("lamport") or 0)
    incoming_origin = row.get("origin_node") or ""

    # Lamport's receive rule, applied for every row we see whether it wins or
    # loses: a quiet device that never advanced its clock would keep stamping
    # low values and lose every future conflict against a chattier peer.
    stamping.observe_lamport(incoming_clock)

    existing = conn.execute(
        "SELECT id, lamport, origin_node, deleted_at FROM nodes WHERE uuid = ?",
        (uuid,),
    ).fetchone()

    if existing is None:
        conn.execute(
            "INSERT INTO nodes(uuid, kind, label, data, created_at, updated_at,"
            " lamport, origin_node, deleted_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                uuid,
                row.get("kind") or "fact",
                row.get("label") or "",
                row.get("data") or "{}",
                # The row's own birthday when the sender knew it; only fall
                # back to updated_at when an older peer omitted it.
                row.get("created_at") or row.get("updated_at") or time.time(),
                row.get("updated_at") or time.time(),
                incoming_clock,
                row.get("origin_node"),
                row.get("deleted_at"),
            ),
        )
        conn.commit()
        return Outcome.inserted

    verdict = decide(
        local_lamport=existing["lamport"],
        local_origin=existing["origin_node"],
        local_deleted=existing["deleted_at"] is not None,
        incoming_lamport=incoming_clock,
        incoming_origin=incoming_origin,
        incoming_deleted=row.get("deleted_at") is not None,
        exists_locally=True,
    )
    if verdict is Outcome.rejected:
        _record_conflict(conn, row)
        return Outcome.rejected

    # A device overwriting its OWN earlier row is linear history, not a
    # disagreement — recording it would bury the real conflicts under noise.
    same_origin = (existing["origin_node"] or "") == incoming_origin

    conn.execute(
        "UPDATE nodes SET kind = ?, label = ?, data = ?, updated_at = ?,"
        " lamport = ?, origin_node = ?, deleted_at = ? WHERE uuid = ?",
        (
            row.get("kind") or "fact",
            row.get("label") or "",
            row.get("data") or "{}",
            row.get("updated_at") or time.time(),
            incoming_clock,
            row.get("origin_node"),
            row.get("deleted_at"),
            uuid,
        ),
    )
    conn.commit()

    if not same_origin:
        # The LOCAL revision just lost. Keep it, for the same reason we keep a
        # losing incoming one.
        _record_conflict(
            conn,
            {
                "uuid": uuid,
                "lamport": int(existing["lamport"] or 0),
                "origin_node": existing["origin_node"],
                "label": None,
                "kind": None,
                "data": None,
            },
        )
    return Outcome.updated


def apply_edge(conn, row: dict[str, Any]) -> Outcome:
    """Same rules, and a dangling endpoint is legal.

    An edge may arrive before its nodes — the schema says so explicitly, and
    rejecting one would silently drop relations whenever an envelope split a
    node from its edge. The user's graph would quietly lose links with nothing
    reporting it.
    """
    uuid = _require_uuid(row)
    incoming_clock = int(row.get("lamport") or 0)
    incoming_origin = row.get("origin_node") or ""
    stamping.observe_lamport(incoming_clock)

    existing = conn.execute(
        "SELECT lamport, origin_node, deleted_at FROM edges WHERE uuid = ?",
        (uuid,),
    ).fetchone()

    if existing is None:
        conn.execute(
            "INSERT INTO edges(uuid, src_uuid, dst_uuid, relation, data,"
            " created_at, updated_at, lamport, origin_node, deleted_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                uuid,
                row["src_uuid"],
                row["dst_uuid"],
                row.get("relation") or "",
                row.get("data") or "{}",
                row.get("updated_at") or time.time(),
                row.get("updated_at") or time.time(),
                incoming_clock,
                row.get("origin_node"),
                row.get("deleted_at"),
            ),
        )
        conn.commit()
        return Outcome.inserted

    if decide(
        local_lamport=existing["lamport"],
        local_origin=existing["origin_node"],
        local_deleted=existing["deleted_at"] is not None,
        incoming_lamport=incoming_clock,
        incoming_origin=incoming_origin,
        incoming_deleted=row.get("deleted_at") is not None,
        exists_locally=True,
    ) is Outcome.rejected:
        _record_conflict(conn, row)
        return Outcome.rejected

    conn.execute(
        "UPDATE edges SET relation = ?, data = ?, updated_at = ?, lamport = ?,"
        " origin_node = ?, deleted_at = ? WHERE uuid = ?",
        (
            row.get("relation") or "",
            row.get("data") or "{}",
            row.get("updated_at") or time.time(),
            incoming_clock,
            row.get("origin_node"),
            row.get("deleted_at"),
            uuid,
        ),
    )
    conn.commit()
    return Outcome.updated


def apply_envelope(
    conn, *, env_id: str, rows: Iterable[dict[str, Any]], edges: Iterable[dict] = ()
) -> EnvelopeResult:
    """Apply one envelope exactly once.

    The relay guarantees at-least-once delivery and never exactly-once, so the
    dedupe has to be here. `remember_applied` is checked FIRST: a redelivered
    envelope must not even reach the merge rules, or it would re-record the
    same conflicts.
    """
    if not stamping.remember_applied(conn, env_id):
        return EnvelopeResult(applied=False)

    outcomes = [apply_node(conn, row) for row in rows]
    outcomes += [apply_edge(conn, row) for row in edges]
    return EnvelopeResult(applied=True, outcomes=tuple(outcomes))
