"""Scans DAO for the posture domain."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Literal

import ulid

from lifeos.posture import store

State = Literal["good", "slouched", "forward_head", "leaning",
                "not_at_desk", "face_not_visible", "error"]
Source = Literal["scheduled", "manual"]
_VALID_STATES = {"good", "slouched", "forward_head", "leaning",
                  "not_at_desk", "face_not_visible", "error"}
_PROBLEMATIC_STATES = {"slouched", "forward_head", "leaning"}


@dataclass(frozen=True, slots=True)
class Scan:
    id: str
    ts: datetime
    state: State
    confidence: float
    suggestion: str | None
    nudge_sent: bool
    source: Source
    raw_response: str | None
    error: str | None
    created_at: datetime | None = None

    @property
    def is_problematic(self) -> bool:
        return self.state in _PROBLEMATIC_STATES


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _row_to_scan(row) -> Scan:
    return Scan(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        state=row["state"],
        confidence=float(row["confidence"]),
        suggestion=row["suggestion"],
        nudge_sent=bool(row["nudge_sent"]),
        source=row["source"],
        raw_response=row["raw_response"],
        error=row["error"],
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
    )


def create(*, when: datetime, state: State, confidence: float = 0.0,
           suggestion: str | None = None, nudge_sent: bool = False,
           source: Source = "scheduled",
           raw_response: str | None = None,
           error: str | None = None) -> Scan:
    if state not in _VALID_STATES:
        raise ValueError(f"state must be one of {_VALID_STATES}, got {state!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware")
    if not (0.0 <= confidence <= 1.0):
        raise ValueError(f"confidence out of range: {confidence!r}")
    sid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO posture_scans(id, ts, state, confidence, suggestion, "
            "nudge_sent, source, raw_response, error) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (sid, _to_iso_utc(when), state, float(confidence), suggestion,
             1 if nudge_sent else 0, source, raw_response, error),
        )
    fetched = get(sid)
    assert fetched is not None
    return fetched


def get(sid: str) -> Scan | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM posture_scans WHERE id = ?", (sid,)
        ).fetchone()
    return _row_to_scan(row) if row else None


def list_recent(*, days: int = 7, limit: int = 200) -> list[Scan]:
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM posture_scans WHERE ts >= datetime('now', ?) "
            "ORDER BY ts DESC LIMIT ?",
            (f"-{int(days)} days", int(limit)),
        ).fetchall()
    return [_row_to_scan(r) for r in rows]


def last_nudge_at() -> datetime | None:
    """Timestamp of the most recent scan that produced a nudge.
    None if no nudge has fired yet."""
    with store.connect() as conn:
        row = conn.execute(
            "SELECT MAX(ts) as t FROM posture_scans WHERE nudge_sent = 1"
        ).fetchone()
    t = row["t"] if row else None
    return _parse_iso(t) if t else None


def in_cooldown(minutes: int) -> bool:
    """True if a nudge fired less than `minutes` minutes ago."""
    last = last_nudge_at()
    if last is None:
        return False
    age = (datetime.now(timezone.utc) - last).total_seconds()
    return age < (minutes * 60)


def summary(*, days: int = 7) -> dict:
    """Counts per state + nudges in the window. Useful for /posture dashboard."""
    out = {
        "total_scans": 0, "nudges_sent": 0,
        "by_state": {},
    }
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT state, COUNT(*) as c, SUM(nudge_sent) as nudges "
            "FROM posture_scans WHERE ts >= datetime('now', ?) "
            "GROUP BY state",
            (f"-{int(days)} days",),
        ).fetchall()
    for r in rows:
        c = int(r["c"]); n = int(r["nudges"] or 0)
        out["by_state"][r["state"]] = c
        out["total_scans"] += c
        out["nudges_sent"] += n
    return out
