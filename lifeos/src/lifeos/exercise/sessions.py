"""Exercise sessions DAO.

Kinds:
    walk        — caminata / paseo
    run         — trote / correr
    cardio      — bici fija / elíptica / cardio en gym
    strength    — pesas / fuerza
    yoga        — yoga / pilates / estiramiento
    sports      — fútbol / tenis / pádel / básquet
    other       — catch-all

`current_streak()` counts consecutive days ending today with ≥ 1 session.
Useful for the dashboard's "días consecutivos" chip — proven motivational
pattern in habit-tracking products.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

import ulid

from lifeos.exercise import store

Kind = Literal["walk", "run", "cardio", "strength", "yoga", "sports", "other"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"walk", "run", "cardio", "strength", "yoga", "sports", "other"}


@dataclass(frozen=True, slots=True)
class Session:
    id: str
    ts: datetime
    kind: Kind
    duration_minutes: int
    intensity: int | None
    mood_pre: int | None
    mood_post: int | None
    location: str | None
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
    subject: str | None = None  # NULL = the user; else family relation label

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


def _row_to_session(row) -> Session:
    data = json.loads(row["data"]) if row["data"] else {}
    tags = [t for t in (row["tags"] or "").split(",") if t]
    keys = row.keys() if hasattr(row, "keys") else []
    return Session(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        kind=row["kind"],
        duration_minutes=int(row["duration_minutes"]),
        intensity=row["intensity"],
        mood_pre=row["mood_pre"],
        mood_post=row["mood_post"],
        location=row["location"],
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
        subject=row["subject"] if "subject" in keys else None,
    )


def _subject_clause(subject: str | None) -> tuple[str, list]:
    """SQL fragment + params for the subject filter.

    "self" (default) → only the user's own rows (subject IS NULL) so summary,
    streak and digest consumers never mix in family data. "any" → no filter.
    Any other string → rows for that family member.
    """
    if subject == "self" or subject is None:
        return " AND subject IS NULL", []
    if subject == "any":
        return "", []
    return " AND subject = ?", [subject]


def _validate_mood(value: int | None, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, int) or not (1 <= value <= 10):
        raise ValueError(f"{label} must be int in 1..10, got {value!r}")


def create(*, kind: Kind, title: str, duration_minutes: int, when: datetime,
           intensity: int | None = None,
           mood_pre: int | None = None,
           mood_post: int | None = None,
           location: str | None = None,
           body: str | None = None,
           data: dict | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None,
           subject: str | None = None) -> Session:
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")
    if duration_minutes < 0 or duration_minutes > 24 * 60:
        raise ValueError(f"duration_minutes out of range: {duration_minutes!r}")
    if intensity is not None and (not isinstance(intensity, int) or not (1 <= intensity <= 10)):
        raise ValueError(f"intensity must be int in 1..10, got {intensity!r}")
    _validate_mood(mood_pre, "mood_pre")
    _validate_mood(mood_post, "mood_post")

    sid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO exercise_sessions(id, ts, kind, duration_minutes, "
            "intensity, mood_pre, mood_post, location, title, body, data, "
            "tags, source, confidence, raw_utterance, source_conv_id, subject) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                sid, _to_iso_utc(when), kind, int(duration_minutes),
                intensity, mood_pre, mood_post, location, title, body,
                json.dumps(data) if data else None,
                ",".join(tags) if tags else None,
                source, float(confidence),
                raw_utterance, source_conv_id, subject,
            ),
        )
    fetched = get(sid)
    assert fetched is not None
    return fetched


def get(sid: str) -> Session | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM exercise_sessions WHERE id = ? AND deleted_at IS NULL",
            (sid,),
        ).fetchone()
    return _row_to_session(row) if row else None


def list_recent(*, days: int = 30, kind: Kind | None = None,
                limit: int = 300, subject: str = "self") -> list[Session]:
    """subject: "self" (default) → the user's own sessions only; "any" →
    everyone; "<name>" → that family member only."""
    q = (
        "SELECT * FROM exercise_sessions WHERE deleted_at IS NULL "
        "AND ts >= datetime('now', ?)"
    )
    params: list = [f"-{int(days)} days"]
    sub_q, sub_params = _subject_clause(subject)
    q += sub_q
    params.extend(sub_params)
    if kind is not None:
        if kind not in _VALID_KINDS:
            raise ValueError(f"invalid kind {kind!r}")
        q += " AND kind = ?"
        params.append(kind)
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(int(limit))
    with store.connect() as conn:
        rows = conn.execute(q, tuple(params)).fetchall()
    return [_row_to_session(r) for r in rows]


def summary(*, days: int = 30, subject: str = "self") -> dict[str, Any]:
    """Aggregates over `days`: total sessions, total minutes, per-kind breakdown.

    Defaults to the user's own sessions (subject IS NULL) so dashboard stats
    and digests never mix in family sessions."""
    sub_q, sub_params = _subject_clause(subject)
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT kind, COUNT(*) as c, COALESCE(SUM(duration_minutes), 0) as m "
            "FROM exercise_sessions "
            "WHERE deleted_at IS NULL AND ts >= datetime('now', ?)"
            f"{sub_q} "
            "GROUP BY kind",
            (f"-{int(days)} days", *sub_params),
        ).fetchall()
    by_kind: dict[str, dict[str, int]] = {}
    total_c = 0
    total_m = 0
    for r in rows:
        c = int(r["c"]); m = int(r["m"])
        by_kind[r["kind"]] = {"count": c, "minutes": m}
        total_c += c
        total_m += m
    return {
        "sessions_count": total_c,
        "total_minutes": total_m,
        "by_kind": by_kind,
    }


def current_streak(*, subject: str = "self") -> int:
    """Consecutive days ending today with at least one session.

    Returns 0 if there's no session today. Uses the row's `ts` field
    (the moment the session happened, not when it was logged). Defaults to
    the user's own sessions — a family member's walk must not extend the
    user's streak.
    """
    sub_q, sub_params = _subject_clause(subject)
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT DISTINCT date(ts) as d FROM exercise_sessions "
            f"WHERE deleted_at IS NULL{sub_q} ORDER BY d DESC",
            tuple(sub_params),
        ).fetchall()
    if not rows:
        return 0
    dates = {r["d"] for r in rows}
    today = datetime.now(timezone.utc).date()
    streak = 0
    cursor = today
    while cursor.isoformat() in dates:
        streak += 1
        cursor = cursor - timedelta(days=1)
    return streak


def delete(sid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE exercise_sessions SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (sid,),
        )
        return cur.rowcount > 0


def update_title(sid: str, title: str) -> bool:
    """Update only the title of a non-deleted exercise session."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE exercise_sessions SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, sid),
        )
        return cur.rowcount > 0
