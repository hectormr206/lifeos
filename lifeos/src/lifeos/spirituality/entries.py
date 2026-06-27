"""Spirituality entries DAO.

Six kinds, all stored in one table:

  reflection   — open-ended personal observation
  gratitude    — gratitude list ("3 cosas que agradezco hoy")
  meditation   — meditation session log
  value        — stated personal value
  retro        — weekly retrospective
  question     — open question Héctor is sitting with

The `data` JSON column is loose per-kind (gratitude → {items: [...]},
retro → {wins, losses, next_focus}). Adding new kinds doesn't require a
migration — only the UI changes.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import ulid

from lifeos.spirituality import store

Kind = Literal["reflection", "gratitude", "meditation", "value", "retro", "question"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"reflection", "gratitude", "meditation", "value", "retro", "question"}


@dataclass(frozen=True, slots=True)
class Entry:
    id: str
    ts: datetime
    kind: Kind
    title: str
    body: str | None
    mood: int | None
    data: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
    reminder_id: str | None = None
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
        mood=row["mood"],
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
           mood: int | None = None,
           data: dict | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           reminder_id: str | None = None,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Entry:
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")
    if mood is not None and (not isinstance(mood, int) or not (1 <= mood <= 10)):
        raise ValueError(f"mood must be int in 1..10, got {mood!r}")

    eid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO spirituality_entries(id, ts, kind, title, body, mood, "
            "data, tags, source, confidence, reminder_id, raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, _to_iso_utc(when), kind, title, body, mood,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                source, float(confidence), reminder_id,
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(eid)
    assert fetched is not None
    return fetched


def get(eid: str) -> Entry | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM spirituality_entries WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        ).fetchone()
    return _row_to_entry(row) if row else None


def list_recent(*, days: int = 30, kind: Kind | None = None,
                limit: int = 300) -> list[Entry]:
    q = (
        "SELECT * FROM spirituality_entries WHERE deleted_at IS NULL "
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
    return [_row_to_entry(r) for r in rows]


def search(query: str, *, kind: Kind | None = None, limit: int = 200) -> list[Entry]:
    if not query.strip():
        return []
    q = (
        "SELECT * FROM spirituality_entries WHERE deleted_at IS NULL "
        "AND (title LIKE ? OR body LIKE ?)"
    )
    needle = f"%{query.strip()}%"
    params: list = [needle, needle]
    if kind is not None:
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_entry(r) for r in rows]


def delete(eid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE spirituality_entries SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        )
        return cur.rowcount > 0


def update_title(eid: str, title: str) -> bool:
    """Update only the title of a non-deleted spirituality entry."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE spirituality_entries SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, eid),
        )
        return cur.rowcount > 0
