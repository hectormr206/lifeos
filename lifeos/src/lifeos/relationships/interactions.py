"""Interactions DAO — events linked to people.

Kinds:
    conversation   — neutral / regular talk
    conflict       — disagreement, argument
    quality_time   — intentional positive time together
    call           — phone or video call
    text           — chat / message exchange
    note           — passive observation (no kind-specific verb)

Optional mood_pre/mood_post (1..10) so the dashboard can plot "how do my
interactions with X tend to leave me feeling" over time.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal

import ulid

from lifeos.relationships import store

Kind = Literal[
    "conversation", "conflict", "quality_time", "call", "text", "note"
]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"conversation", "conflict", "quality_time", "call", "text", "note"}


@dataclass(frozen=True, slots=True)
class Interaction:
    id: str
    ts: datetime
    person_id: str
    kind: Kind
    title: str
    body: str | None
    mood_pre: int | None
    mood_post: int | None
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
    created_at: datetime | None = None
    deleted_at: datetime | None = None
    raw_utterance: str | None = None
    source_conv_id: int | None = None

    @property
    def mood_delta(self) -> int | None:
        if self.mood_pre is None or self.mood_post is None:
            return None
        return self.mood_post - self.mood_pre


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _row_to_interaction(row) -> Interaction:
    tags = [t for t in (row["tags"] or "").split(",") if t]
    keys = row.keys() if hasattr(row, "keys") else []
    return Interaction(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        person_id=row["person_id"],
        kind=row["kind"],
        title=row["title"],
        body=row["body"],
        mood_pre=row["mood_pre"],
        mood_post=row["mood_post"],
        tags=tags,
        source=row["source"],
        confidence=float(row["confidence"]),
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
        deleted_at=_parse_iso(row["deleted_at"]) if row["deleted_at"] else None,
        raw_utterance=row["raw_utterance"] if "raw_utterance" in keys else None,
        source_conv_id=row["source_conv_id"] if "source_conv_id" in keys else None,
    )


def _validate_mood(value: int | None, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, int) or not (1 <= value <= 10):
        raise ValueError(f"{label} must be an int in 1..10, got {value!r}")


def create(*, person_id: str, kind: Kind, title: str, when: datetime,
           body: str | None = None,
           mood_pre: int | None = None,
           mood_post: int | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Interaction:
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")
    _validate_mood(mood_pre, "mood_pre")
    _validate_mood(mood_post, "mood_post")

    # Enforce that the person exists (and is not deleted).
    from lifeos.relationships import people
    if people.get(person_id) is None:
        raise ValueError(f"person {person_id!r} not found")

    iid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO interactions(id, ts, person_id, kind, title, body, "
            "mood_pre, mood_post, tags, source, confidence, "
            "raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                iid, _to_iso_utc(when), person_id, kind, title, body,
                mood_pre, mood_post,
                ",".join(tags) if tags else None,
                source, float(confidence),
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(iid)
    assert fetched is not None
    return fetched


def get(iid: str) -> Interaction | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM interactions WHERE id = ? AND deleted_at IS NULL", (iid,)
        ).fetchone()
    return _row_to_interaction(row) if row else None


def timeline_for(person_id: str, *, days: int = 365, limit: int = 200) -> list[Interaction]:
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM interactions "
            "WHERE deleted_at IS NULL "
            "AND person_id = ? "
            "AND ts >= datetime('now', ?) "
            "ORDER BY ts DESC LIMIT ?",
            (person_id, f"-{int(days)} days", int(limit)),
        ).fetchall()
    return [_row_to_interaction(r) for r in rows]


def list_recent(*, days: int = 30, kind: Kind | None = None,
                limit: int = 300) -> list[Interaction]:
    q = (
        "SELECT * FROM interactions WHERE deleted_at IS NULL "
        "AND ts >= datetime('now', ?)"
    )
    params: list = [f"-{int(days)} days"]
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_interaction(r) for r in rows]


def conflict_history(person_id: str, *, days: int = 365) -> list[Interaction]:
    """All conflicts with a given person, newest first."""
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM interactions "
            "WHERE deleted_at IS NULL AND person_id = ? AND kind = 'conflict' "
            "AND ts >= datetime('now', ?) ORDER BY ts DESC",
            (person_id, f"-{int(days)} days"),
        ).fetchall()
    return [_row_to_interaction(r) for r in rows]


def delete(iid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE interactions SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (iid,),
        )
        return cur.rowcount > 0


def update_title(iid: str, title: str) -> bool:
    """Update only the title of a non-deleted interaction."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE interactions SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, iid),
        )
        return cur.rowcount > 0
