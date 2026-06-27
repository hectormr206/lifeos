"""Learning entries DAO.

Seven kinds, all in one table:

  book                — a book the user is reading / has read / wants to read
  course              — an online course / class
  article             — an article / blog post / paper
  idea                — an idea worth exploring
  research_question   — a question/topic to investigate
  note                — generic learning note
  quote               — a quote from a source

For books/courses, `status` evolves from active/someday → done/abandoned.
`mark_done(id, rating=N)` is the typical state transition for a finished
book or course.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import ulid

from lifeos.learning import store

Kind = Literal["book", "course", "article", "idea", "research_question",
               "note", "quote"]
Status = Literal["active", "done", "abandoned", "someday"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"book", "course", "article", "idea", "research_question",
                "note", "quote"}
_VALID_STATUSES = {"active", "done", "abandoned", "someday"}


@dataclass(frozen=True, slots=True)
class Entry:
    id: str
    ts: datetime
    kind: Kind
    title: str
    body: str | None
    author: str | None
    status: Status
    progress: str | None
    rating: int | None
    data: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
    completed_at: datetime | None = None
    created_at: datetime | None = None
    deleted_at: datetime | None = None
    raw_utterance: str | None = None
    source_conv_id: int | None = None


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _row_to_entry(row) -> Entry:
    data = json.loads(row["data"]) if row["data"] else {}
    tags = [t for t in (row["tags"] or "").split(",") if t]
    keys = row.keys() if hasattr(row, "keys") else []
    return Entry(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        kind=row["kind"],
        title=row["title"],
        body=row["body"],
        author=row["author"],
        status=row["status"],
        progress=row["progress"],
        rating=row["rating"],
        data=data,
        tags=tags,
        source=row["source"],
        confidence=float(row["confidence"]),
        completed_at=_parse_iso(row["completed_at"]) if row["completed_at"] else None,
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
        deleted_at=_parse_iso(row["deleted_at"]) if row["deleted_at"] else None,
        raw_utterance=row["raw_utterance"] if "raw_utterance" in keys else None,
        source_conv_id=row["source_conv_id"] if "source_conv_id" in keys else None,
    )


def _validate_rating(rating: int | None) -> None:
    if rating is None:
        return
    if not isinstance(rating, int) or not (1 <= rating <= 10):
        raise ValueError(f"rating must be int in 1..10, got {rating!r}")


def create(*, kind: Kind, title: str, when: datetime,
           body: str | None = None,
           author: str | None = None,
           status: Status = "active",
           progress: str | None = None,
           rating: int | None = None,
           data: dict | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Entry:
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if status not in _VALID_STATUSES:
        raise ValueError(f"status must be one of {_VALID_STATUSES}, got {status!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")
    _validate_rating(rating)

    eid = str(ulid.new())
    completed_at = _to_iso_utc(datetime.now(timezone.utc)) if status == "done" else None
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO learning_entries(id, ts, kind, title, body, author, "
            "status, progress, rating, data, tags, source, confidence, completed_at, "
            "raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, _to_iso_utc(when), kind, title, body, author,
                status, progress, rating,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                source, float(confidence), completed_at,
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(eid)
    assert fetched is not None
    return fetched


def get(eid: str) -> Entry | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM learning_entries WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        ).fetchone()
    return _row_to_entry(row) if row else None


def list_recent(*, days: int = 365, kind: Kind | None = None,
                status: Status | None = None, limit: int = 200) -> list[Entry]:
    q = (
        "SELECT * FROM learning_entries WHERE deleted_at IS NULL "
        "AND ts >= datetime('now', ?)"
    )
    params: list = [f"-{int(days)} days"]
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    if status is not None:
        if status not in _VALID_STATUSES:
            raise ValueError(f"invalid status {status!r}")
        q += " AND status = ?"
        params.append(status)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_entry(r) for r in rows]


def active_books(limit: int = 50) -> list[Entry]:
    """Books currently active (in progress)."""
    return list_recent(days=3650, kind="book", status="active", limit=limit)


def search(query: str, *, kind: Kind | None = None, limit: int = 200) -> list[Entry]:
    if not query.strip():
        return []
    q = (
        "SELECT * FROM learning_entries WHERE deleted_at IS NULL "
        "AND (title LIKE ? OR body LIKE ? OR author LIKE ?)"
    )
    needle = f"%{query.strip()}%"
    params: list = [needle, needle, needle]
    if kind is not None:
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_entry(r) for r in rows]


def mark_done(eid: str, *, rating: int | None = None) -> None:
    if rating is not None:
        _validate_rating(rating)
    with store.connect() as conn:
        if rating is not None:
            conn.execute(
                "UPDATE learning_entries SET status='done', "
                "completed_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), rating = ? "
                "WHERE id = ? AND deleted_at IS NULL",
                (rating, eid),
            )
        else:
            conn.execute(
                "UPDATE learning_entries SET status='done', "
                "completed_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
                "WHERE id = ? AND deleted_at IS NULL",
                (eid,),
            )


def update_progress(eid: str, *, progress: str) -> None:
    with store.connect() as conn:
        conn.execute(
            "UPDATE learning_entries SET progress = ? "
            "WHERE id = ? AND deleted_at IS NULL",
            (progress, eid),
        )


def delete(eid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE learning_entries SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        )
        return cur.rowcount > 0


def update_title(eid: str, title: str) -> bool:
    """Update only the title of a non-deleted learning entry."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE learning_entries SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, eid),
        )
        return cur.rowcount > 0
