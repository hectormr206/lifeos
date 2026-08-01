"""People DAO — first-class entities in the relationships domain.

Names are case-insensitively unique among non-deleted rows. `find_by_name`
uses EXACT case-insensitive match (accents matter — "María" ≠ "Maria").
Ingestion uses `get_or_create` to never duplicate.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

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
    # The DATE, never an age: an age is wrong within a year and the assistant
    # would keep stating it confidently.
    birth_date: date | None = None
    # "talk every six weeks". The due date it implies is COMPUTED from the last
    # real interaction — see due_for_contact — so an unplanned message cannot
    # leave a stale schedule behind.
    contact_cadence_days: int | None = None


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _optional(row, column: str):
    """Read a column that older rows may predate. Keeps the DAO working against
    a database migrated a moment ago in another process."""
    try:
        return row[column]
    except (IndexError, KeyError):
        return None


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def _row_to_person(row) -> Person:
    return Person(
        id=row["id"],
        name=row["name"],
        role=row["role"],
        since=_parse_iso(row["since"]),
        color=row["color"],
        notes=row["notes"],
        created_at=_parse_iso(row["created_at"]),
        birth_date=_parse_date(_optional(row, "birth_date")),
        contact_cadence_days=_optional(row, "contact_cadence_days"),
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


# ─── Birth dates ────────────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class Birthday:
    person: Person
    on: date          # the date it falls on THIS time round
    turning: int      # the age they reach on it


def set_birth_date(pid: str, value: date | None) -> None:
    """Set or clear a birth date. Pass None when it was recorded wrong —
    a wrong date is worse than none, because it produces a confident greeting
    on the wrong day."""
    with store.connect() as conn:
        conn.execute(
            "UPDATE people SET birth_date = ? WHERE id = ? AND deleted_at IS NULL",
            (value.isoformat() if value else None, pid),
        )


def age_on(pid: str, *, on: date) -> int | None:
    """Age at [on], computed. None when no birth date is known."""
    person = get(pid)
    if person is None or person.birth_date is None:
        return None
    return _age_between(person.birth_date, on)


def _age_between(born: date, on: date) -> int:
    return on.year - born.year - ((on.month, on.day) < (born.month, born.day))


def _birthday_in_year(born: date, year: int) -> date:
    """The date the birthday falls on in [year].

    29 February lands on the 28th in a common year. Skipping it instead would
    silently drop a real birthday three years out of four.
    """
    try:
        return born.replace(year=year)
    except ValueError:
        return date(year, 2, 28)


def upcoming_birthdays(*, within_days: int, today: date) -> list[Birthday]:
    """Birthdays falling in the next [within_days], soonest first.

    Everyone with a date is included — a friend's children matter as much as
    the friend, and are usually the better reason to reach out.
    """
    out: list[Birthday] = []
    for person in list_all():
        if person.birth_date is None:
            continue
        # Try this year and next, so a window crossing New Year still finds it.
        for year in (today.year, today.year + 1):
            on = _birthday_in_year(person.birth_date, year)
            if today <= on <= today + timedelta(days=within_days):
                out.append(
                    Birthday(
                        person=person,
                        on=on,
                        turning=_age_between(person.birth_date, on),
                    )
                )
                break
    return sorted(out, key=lambda b: b.on)


# ─── Links between people ───────────────────────────────────────────────────

#: Inverse of each link kind, used to answer from the other side without
#: storing two rows that could disagree.
_INVERSE: dict[str, str] = {
    "partner": "partner",
    "child": "parent",
    "parent": "child",
    "sibling": "sibling",
    "friend": "friend",
}


@dataclass(frozen=True, slots=True)
class Relation:
    person: Person    # the OTHER person
    kind: str         # as seen from the person asked about


def link(from_id: str, to_id: str, kind: str) -> None:
    """Record that [to_id] is the [kind] of [from_id]. Idempotent; re-linking
    with a different kind corrects it."""
    if from_id == to_id:
        raise ValueError("a person cannot be their own relative")
    with store.connect() as conn:
        conn.execute(
            """
            INSERT INTO person_links(from_id, to_id, kind) VALUES (?, ?, ?)
            ON CONFLICT(from_id, to_id) DO UPDATE SET kind = excluded.kind
            """,
            (from_id, to_id, kind),
        )


def unlink(a_id: str, b_id: str) -> None:
    """Remove the link in whichever direction it was stored."""
    with store.connect() as conn:
        conn.execute(
            "DELETE FROM person_links WHERE (from_id = ? AND to_id = ?) "
            "OR (from_id = ? AND to_id = ?)",
            (a_id, b_id, b_id, a_id),
        )


def related_to(pid: str) -> list[Relation]:
    """Everyone linked to [pid], with the kind as seen FROM [pid].

    One row per pair is stored; the reverse direction is derived here, so the
    two views can never drift apart.
    """
    out: list[Relation] = []
    with store.connect() as conn:
        forward = conn.execute(
            "SELECT to_id, kind FROM person_links WHERE from_id = ?", (pid,)
        ).fetchall()
        backward = conn.execute(
            "SELECT from_id, kind FROM person_links WHERE to_id = ?", (pid,)
        ).fetchall()
    for row in forward:
        other = get(row["to_id"])
        if other is not None:
            out.append(Relation(person=other, kind=row["kind"]))
    for row in backward:
        other = get(row["from_id"])
        if other is not None:
            out.append(
                Relation(person=other, kind=_INVERSE.get(row["kind"], row["kind"]))
            )
    return sorted(out, key=lambda r: r.person.name.lower())


# ─── Contact cadence ────────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class ContactDue:
    person: Person
    days_since: int
    last_contact: datetime | None


def set_contact_cadence(pid: str, *, days: int | None) -> None:
    """"Talk to Juan every six weeks", or None to stop tracking it."""
    with store.connect() as conn:
        conn.execute(
            "UPDATE people SET contact_cadence_days = ? "
            "WHERE id = ? AND deleted_at IS NULL",
            (days, pid),
        )


def last_contact(pid: str) -> datetime | None:
    """When they last actually talked, DERIVED from interactions.

    Never stored: a stored copy goes stale the moment a conversation is
    recorded through any other path, and the whole point of the cadence is that
    it tracks reality rather than a schedule.
    """
    with store.connect() as conn:
        row = conn.execute(
            "SELECT MAX(ts) AS ts FROM interactions "
            "WHERE person_id = ? AND deleted_at IS NULL",
            (pid,),
        ).fetchone()
    return _parse_iso(row["ts"]) if row and row["ts"] else None


def due_for_contact(*, now: datetime) -> list[ContactDue]:
    """People whose cadence has elapsed since the last real conversation.

    Talking again resets this with no rescheduling anywhere: the answer is
    recomputed from interactions every time. That is the difference from a
    cron-shaped model, which desynchronises the first time the user messages
    someone off-schedule.

    Someone never contacted is measured from when they were added, so a new
    person is neither due immediately nor never.
    """
    out: list[ContactDue] = []
    for person in list_all():
        if not person.contact_cadence_days:
            continue
        since = last_contact(person.id) or person.created_at
        if since is None:
            continue
        if since.tzinfo is None:
            since = since.replace(tzinfo=timezone.utc)
        days = (now - since).days
        if days >= person.contact_cadence_days:
            out.append(
                ContactDue(
                    person=person,
                    days_since=days,
                    last_contact=last_contact(person.id),
                )
            )
    return sorted(out, key=lambda d: -d.days_since)
