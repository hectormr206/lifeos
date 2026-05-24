"""Graph edges across LifeOS domains.

This is the substrate for cross-domain reasoning. An edge links two
entries by id+domain+relation. The actual entries live in their per-
domain (often encrypted) stores; this module only handles the connecting
metadata.

Public surface:
    create(src=(domain, id), dst=(domain, id), rel=...) → Edge
    neighbors(domain, id, rel=None) → list[Edge]
    inbound(domain, id, rel=None) → list[Edge]
    by_relation(rel, *, src_domain=None, dst_domain=None) → list[Edge]
    delete(edge_id) → bool

The controlled `rel` vocabulary lives in REL_VOCAB. Callers can use any
string, but the recommended ones surface in higher-level helpers and
tests.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

import ulid

from lifeos import store

REL_VOCAB = frozenset({
    "caused-by", "precedes", "same-event",
    "mentions-person", "resolved-by", "pattern-of",
    "triggered-by", "funded", "costs",
    # Correlation Engine (P6.3)
    "correlates-with", "pattern-active-at",
})


@dataclass(frozen=True, slots=True)
class Edge:
    id: str
    src_id: str
    src_domain: str
    dst_id: str
    dst_domain: str
    rel: str
    weight: float = 1.0
    metadata: dict | None = None
    created_at: datetime | None = None
    created_by: str = "system"


EntryRef = tuple[str, str]   # (domain, id)


def _row_to_edge(row) -> Edge:
    md = json.loads(row["metadata"]) if row["metadata"] else None
    created = row["created_at"]
    return Edge(
        id=row["id"],
        src_id=row["src_id"], src_domain=row["src_domain"],
        dst_id=row["dst_id"], dst_domain=row["dst_domain"],
        rel=row["rel"],
        weight=float(row["weight"]),
        metadata=md,
        created_at=(
            datetime.fromisoformat(created).replace(tzinfo=timezone.utc)
            if created and "T" not in created
            else datetime.fromisoformat(created.replace("Z", "+00:00")) if created else None
        ),
        created_by=row["created_by"],
    )


def create(*, src: EntryRef, dst: EntryRef, rel: str,
           weight: float = 1.0, metadata: dict | None = None,
           created_by: str = "system") -> Edge:
    """Create an edge. Returns the persisted Edge."""
    if not src[0] or not src[1] or not dst[0] or not dst[1]:
        raise ValueError("src and dst must be (domain, id) with both non-empty")
    if not rel:
        raise ValueError("rel is required")
    eid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO edges(id, src_id, src_domain, dst_id, dst_domain, "
            "rel, weight, metadata, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, src[1], src[0], dst[1], dst[0], rel,
                float(weight),
                json.dumps(metadata) if metadata else None,
                created_by,
            ),
        )
        row = conn.execute(
            "SELECT * FROM edges WHERE id = ?", (eid,)
        ).fetchone()
    return _row_to_edge(row)


def neighbors(domain: str, entry_id: str, rel: str | None = None) -> list[Edge]:
    """Outbound edges from (domain, entry_id). If `rel` is given, only that."""
    q = "SELECT * FROM edges WHERE src_domain = ? AND src_id = ?"
    params: list = [domain, entry_id]
    if rel is not None:
        q += " AND rel = ?"
        params.append(rel)
    q += " ORDER BY created_at DESC"
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_edge(r) for r in rows]


def inbound(domain: str, entry_id: str, rel: str | None = None) -> list[Edge]:
    """Edges that point TO (domain, entry_id)."""
    q = "SELECT * FROM edges WHERE dst_domain = ? AND dst_id = ?"
    params: list = [domain, entry_id]
    if rel is not None:
        q += " AND rel = ?"
        params.append(rel)
    q += " ORDER BY created_at DESC"
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_edge(r) for r in rows]


def by_relation(rel: str, *, src_domain: str | None = None,
                dst_domain: str | None = None, limit: int = 200) -> list[Edge]:
    """All edges with a given relation, optionally filtered by domains."""
    q = "SELECT * FROM edges WHERE rel = ?"
    params: list = [rel]
    if src_domain:
        q += " AND src_domain = ?"
        params.append(src_domain)
    if dst_domain:
        q += " AND dst_domain = ?"
        params.append(dst_domain)
    q += " ORDER BY created_at DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_edge(r) for r in rows]


def delete(edge_id: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute("DELETE FROM edges WHERE id = ?", (edge_id,))
        return cur.rowcount > 0


def link_many(src: EntryRef, dsts: Iterable[EntryRef], rel: str,
              created_by: str = "system") -> list[Edge]:
    """Convenience: link `src` to many destinations with the same relation."""
    return [
        create(src=src, dst=dst, rel=rel, created_by=created_by)
        for dst in dsts
    ]
