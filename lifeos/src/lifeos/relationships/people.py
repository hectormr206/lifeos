"""People DAO — first-class entities in the relationships domain.

Names are case-insensitively unique among non-deleted rows. `find_by_name`
uses EXACT case-insensitive match (accents matter — "María" ≠ "Maria").
Ingestion uses `get_or_create` to never duplicate.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

import ulid

from lifeos.relationships import store


@dataclass(frozen=True, slots=True)
class Person:
    id: str
    name: str
    role: str | None
    since: datetime | None
    color: str | None
    notes: str | None
    created_at: datetime | None = None


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _row_to_person(row) -> Person:
    return Person(
        id=row["id"],
        name=row["name"],
        role=row["role"],
        since=_parse_iso(row["since"]),
        color=row["color"],
        notes=row["notes"],
        created_at=_parse_iso(row["created_at"]),
    )


def create(*, name: str, role: str | None = None,
           since: datetime | None = None,
           color: str | None = None,
           notes: str | None = None) -> Person:
    name = (name or "").strip()
    if not name:
        raise ValueError("name is required")
    if since is not None and since.tzinfo is None:
        raise ValueError("since must be tz-aware")
    pid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO people(id, name, role, since, color, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (pid, name, role,
             since.isoformat() if since else None,
             color, notes),
        )
    p = get(pid)
    assert p is not None
    return p


def get(pid: str) -> Person | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM people WHERE id = ? AND deleted_at IS NULL", (pid,)
        ).fetchone()
    return _row_to_person(row) if row else None


def find_by_name(name: str) -> Person | None:
    """Exact case-insensitive match. Accents are significant.

    SQLite's built-in LOWER() doesn't lowercase non-ASCII chars (so "Í"
    stays "Í"). We pull all candidates with case-insensitive ASCII match
    via LIKE first, then filter precisely in Python.
    """
    needle = (name or "").strip()
    if not needle:
        return None
    needle_lower = needle.lower()
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM people WHERE name LIKE ? AND deleted_at IS NULL",
            (needle,),
        ).fetchall()
    # Tight filter in Python: full Unicode-aware case-insensitive equality.
    for row in rows:
        if row["name"].lower() == needle_lower:
            return _row_to_person(row)
    # Fallback: scan all (handles the case where LIKE didn't match because
    # of cased-Unicode mismatches).
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM people WHERE deleted_at IS NULL"
        ).fetchall()
    for row in rows:
        if row["name"].lower() == needle_lower:
            return _row_to_person(row)
    return None


def get_or_create(*, name: str, role: str | None = None) -> Person:
    """Idempotent helper for chat ingestion."""
    existing = find_by_name(name)
    if existing:
        return existing
    return create(name=name, role=role)


def list_all() -> list[Person]:
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM people WHERE deleted_at IS NULL ORDER BY name COLLATE NOCASE"
        ).fetchall()
    return [_row_to_person(r) for r in rows]


def update(pid: str, *, role: str | None = None,
           color: str | None = None, notes: str | None = None) -> Person | None:
    fields = []
    params: list = []
    if role is not None:
        fields.append("role = ?")
        params.append(role)
    if color is not None:
        fields.append("color = ?")
        params.append(color)
    if notes is not None:
        fields.append("notes = ?")
        params.append(notes)
    if not fields:
        return get(pid)
    params.append(pid)
    with store.connect() as conn:
        conn.execute(
            f"UPDATE people SET {', '.join(fields)} "
            "WHERE id = ? AND deleted_at IS NULL",
            tuple(params),
        )
    return get(pid)


def delete(pid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE people SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (pid,),
        )
        return cur.rowcount > 0
