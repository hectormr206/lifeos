"""Events DAO — date-anchored entries (catch-all domain).

Kinds:
    travel       — a trip
    party        — a party / social event
    milestone    — a life milestone
    anniversary  — anniversary / recurring date
    birthday     — birthday of someone
    meeting      — scheduled meeting / appointment
    deadline     — a deadline / due date
    other        — catch-all within the catch-all

Status is DERIVED from `ts` vs now (no stored status column):
  ts > now  → upcoming
  ts <= now → past

`people` is a denormalized list of names attached to the event. The
relationships domain (P5.1) is the source of truth for people; here we
store names verbatim for resilience (an event mentioning "Juan" still
makes sense even if no relationships.Person row exists yet).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import ulid

from lifeos.events import store

Kind = Literal["travel", "party", "milestone", "anniversary", "birthday",
               "meeting", "deadline", "other"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"travel", "party", "milestone", "anniversary", "birthday",
                "meeting", "deadline", "other"}


@dataclass(frozen=True, slots=True)
class Event:
    id: str
    ts: datetime
    kind: Kind
    title: str
    body: str | None
    location: str | None
    people: list[str] = field(default_factory=list)
    data: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
    reminder_id: str | None = None
    created_at: datetime | None = None
    deleted_at: datetime | None = None
    raw_utterance: str | None = None
    source_conv_id: int | None = None

    @property
    def is_upcoming(self) -> bool:
        return self.ts > datetime.now(timezone.utc)


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _row_to_event(row) -> Event:
    data = json.loads(row["data"]) if row["data"] else {}
    tags = [t for t in (row["tags"] or "").split(",") if t]
    people = [p for p in (row["people"] or "").split(",") if p]
    keys = row.keys() if hasattr(row, "keys") else []
    return Event(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        kind=row["kind"],
        title=row["title"],
        body=row["body"],
        location=row["location"],
        people=people,
        data=data,
        tags=tags,
        source=row["source"],
        confidence=float(row["confidence"]),
        reminder_id=row["reminder_id"],
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
        deleted_at=_parse_iso(row["deleted_at"]) if row["deleted_at"] else None,
        raw_utterance=row["raw_utterance"] if "raw_utterance" in keys else None,
        source_conv_id=row["source_conv_id"] if "source_conv_id" in keys else None,
    )


def create(*, kind: Kind, title: str, when: datetime,
           body: str | None = None,
           location: str | None = None,
           people: list[str] | None = None,
           data: dict | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           reminder_id: str | None = None,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Event:
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")

    eid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO events(id, ts, kind, title, body, location, people, "
            "data, tags, source, confidence, reminder_id, raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, _to_iso_utc(when), kind, title, body, location,
                ",".join(people) if people else None,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                source, float(confidence), reminder_id,
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(eid)
    assert fetched is not None
    return fetched


def get(eid: str) -> Event | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM events WHERE id = ? AND deleted_at IS NULL", (eid,)
        ).fetchone()
    return _row_to_event(row) if row else None


def list_recent(*, days_back: int = 30, days_ahead: int = 90,
                kind: Kind | None = None, limit: int = 300) -> list[Event]:
    """All events in [now-days_back, now+days_ahead]."""
    q = (
        "SELECT * FROM events WHERE deleted_at IS NULL "
        "AND ts >= datetime('now', ?) AND ts <= datetime('now', ?)"
    )
    params: list = [f"-{int(days_back)} days", f"+{int(days_ahead)} days"]
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts ASC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_event(r) for r in rows]


def upcoming(*, days_ahead: int = 90, kind: Kind | None = None,
             limit: int = 100) -> list[Event]:
    """Events whose ts is in the future, ascending."""
    q = (
        "SELECT * FROM events WHERE deleted_at IS NULL "
        "AND ts > strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
        "AND ts <= datetime('now', ?)"
    )
    params: list = [f"+{int(days_ahead)} days"]
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts ASC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_event(r) for r in rows]


def past(*, days_back: int = 30, kind: Kind | None = None,
         limit: int = 100) -> list[Event]:
    """Past events, descending (newest first)."""
    q = (
        "SELECT * FROM events WHERE deleted_at IS NULL "
        "AND ts <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
        "AND ts >= datetime('now', ?)"
    )
    params: list = [f"-{int(days_back)} days"]
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_event(r) for r in rows]


def search(query: str, *, kind: Kind | None = None, limit: int = 200) -> list[Event]:
    if not query.strip():
        return []
    q = (
        "SELECT * FROM events WHERE deleted_at IS NULL "
        "AND (title LIKE ? OR body LIKE ? OR people LIKE ? OR location LIKE ?)"
    )
    needle = f"%{query.strip()}%"
    params: list = [needle, needle, needle, needle]
    if kind is not None:
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_event(r) for r in rows]


def delete(eid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE events SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        )
        return cur.rowcount > 0


def update_title(eid: str, title: str) -> bool:
    """Update only the title of a non-deleted event."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE events SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, eid),
        )
        return cur.rowcount > 0
