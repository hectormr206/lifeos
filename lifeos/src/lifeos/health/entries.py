"""DAO for the health domain.

Five kinds, all stored in the same encrypted table. The `data` JSON column
holds kind-specific structured fields so we can evolve each kind's schema
without migrations:

  symptom    {severity?: 1-10, location?: str, duration_hours?: number}
  medication {name: str, dose?: str, frequency?: str}
  vital      {type: 'glucose'|'bp_systolic'|'bp_diastolic'|'weight'|...,
              value: number, unit: str}
  condition  {name: str, status?: 'active'|'resolved'}
  note       {} — title+body only

Everything ts-aware (UTC at the boundary). Free-form `title` and optional
`body`. `tags` for ad-hoc grouping. `source` is provenance: 'manual',
'chat' (auto-extracted from chat text), or 'voice' (from a voice command).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import ulid

from lifeos.health import store

Kind = Literal["symptom", "medication", "vital", "condition", "note"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"symptom", "medication", "vital", "condition", "note"}


@dataclass(frozen=True, slots=True)
class Entry:
    id: str
    ts: datetime
    kind: Kind
    title: str
    body: str | None
    data: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
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
        data=data,
        tags=tags,
        source=row["source"],
        confidence=float(row["confidence"]),
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
        deleted_at=_parse_iso(row["deleted_at"]) if row["deleted_at"] else None,
        raw_utterance=row["raw_utterance"] if "raw_utterance" in keys else None,
        source_conv_id=row["source_conv_id"] if "source_conv_id" in keys else None,
    )


def create(*, kind: Kind, title: str, when: datetime,
           body: str | None = None,
           data: dict | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Entry:
    """Insert a new health entry."""
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    eid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO health_entries(id, ts, kind, title, body, data, tags, "
            "source, confidence, raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, _to_iso_utc(when), kind, title, body,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                source, float(confidence),
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(eid)
    assert fetched is not None
    return fetched


def get(eid: str, *, include_deleted: bool = False) -> Entry | None:
    with store.connect() as conn:
        if include_deleted:
            row = conn.execute(
                "SELECT * FROM health_entries WHERE id = ?", (eid,)
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM health_entries WHERE id = ? AND deleted_at IS NULL",
                (eid,),
            ).fetchone()
    return _row_to_entry(row) if row else None


def list_recent(*, days: int = 30, kind: Kind | None = None,
                limit: int = 200) -> list[Entry]:
    """Recent entries (newest first), optionally filtered by kind."""
    q = (
        "SELECT * FROM health_entries WHERE deleted_at IS NULL "
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
    """Naive LIKE search across title + body. FTS5 would be nice but
    SQLite FTS5 isn't enabled in the sqlcipher3-wheels build. Fine for
    a single-user dataset that will stay well under 100k rows."""
    if not query.strip():
        return []
    q = (
        "SELECT * FROM health_entries WHERE deleted_at IS NULL "
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
    """Soft-delete: set deleted_at, keep the row so future undo works."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE health_entries SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        )
        return cur.rowcount > 0


def update_title(eid: str, title: str) -> bool:
    """Update only the title of a non-deleted health entry."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE health_entries SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, eid),
        )
        return cur.rowcount > 0


def update(
    eid: str,
    *,
    kind: Kind,
    title: str,
    when: datetime,
    body: str | None = None,
    data: dict | None = None,
    tags: list[str] | None = None,
) -> "Entry | None":
    """Update a non-deleted health entry.

    Returns the updated Entry, or None if no active row matched (e.g. the
    entry does not exist or has been soft-deleted).
    Raises ValueError for invalid kind or naive datetimes (mirrors create()).

    Note: source and confidence are immutable provenance — they are set at
    creation and cannot be edited here.
    """
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE health_entries "
            "SET ts=?, kind=?, title=?, body=?, data=?, tags=? "
            "WHERE id=? AND deleted_at IS NULL",
            (
                _to_iso_utc(when),
                kind,
                title,
                body,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                eid,
            ),
        )
        if cur.rowcount == 0:
            return None
    return get(eid)
