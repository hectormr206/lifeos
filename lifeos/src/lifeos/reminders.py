"""Reminders DAO — CRUD over the `reminders` table.

Reminders are the simplest thing in P1: a one-shot scheduled message. The
scheduler picks up `status='pending'` rows on boot and dispatches each one
at its `when_ts`. Channels in v1: 'push' (Web Push to subscribed PWAs) and
'log' (just writes to journal — useful for testing without a phone).

Times in the API are tz-aware datetimes; we serialize as ISO8601 UTC.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal

import ulid

from lifeos import store

Channel = Literal["push", "log"]
Status = Literal["pending", "fired", "cancelled", "failed"]


@dataclass(frozen=True, slots=True)
class Reminder:
    id: str
    when_ts: datetime
    message: str
    channel: Channel
    status: Status
    created_at: datetime
    fired_at: datetime | None
    error: str | None


def _row_to_reminder(row) -> Reminder:
    return Reminder(
        id=row["id"],
        when_ts=_parse_iso(row["when_ts"]),
        message=row["message"],
        channel=row["channel"],
        status=row["status"],
        created_at=_parse_iso(row["created_at"]),
        fired_at=_parse_iso(row["fired_at"]) if row["fired_at"] else None,
        error=row["error"],
    )


def _parse_iso(s: str) -> datetime:
    # SQLite datetime('now') gives "YYYY-MM-DD HH:MM:SS" (no TZ);
    # our writes use ISO8601 with Z. Handle both.
    if "T" in s:
        # ISO8601, possibly with 'Z'
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    # SQLite naive UTC default — interpret as UTC
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def create(*, when: datetime, message: str, channel: Channel = "push") -> Reminder:
    """Insert a new pending reminder."""
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    rid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO reminders(id, when_ts, message, channel, status) "
            "VALUES (?, ?, ?, ?, 'pending')",
            (rid, _to_iso_utc(when), message, channel),
        )
    fetched = get(rid)
    assert fetched is not None
    return fetched


def get(rid: str) -> Reminder | None:
    with store.connect() as conn:
        row = conn.execute(
            "SELECT * FROM reminders WHERE id = ?", (rid,)
        ).fetchone()
    return _row_to_reminder(row) if row else None


def list_pending() -> list[Reminder]:
    """All reminders not yet fired or cancelled, sorted by `when_ts` ascending."""
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM reminders WHERE status = 'pending' ORDER BY when_ts ASC"
        ).fetchall()
    return [_row_to_reminder(r) for r in rows]


def list_recent(days: int = 30) -> list[Reminder]:
    """Reminders (any status) created or fired within the last `days` days."""
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM reminders "
            "WHERE when_ts >= datetime('now', ?) OR "
            "      fired_at >= datetime('now', ?) "
            "ORDER BY when_ts DESC",
            (f"-{days} days", f"-{days} days"),
        ).fetchall()
    return [_row_to_reminder(r) for r in rows]


def mark_fired(rid: str) -> None:
    with store.connect() as conn:
        conn.execute(
            "UPDATE reminders SET status='fired', "
            "fired_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND status = 'pending'",
            (rid,),
        )


def mark_failed(rid: str, error: str) -> None:
    with store.connect() as conn:
        conn.execute(
            "UPDATE reminders SET status='failed', error = ?, "
            "fired_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ?",
            (error, rid),
        )


def cancel(rid: str) -> bool:
    """Cancel a pending reminder. Returns True if state changed."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE reminders SET status='cancelled' "
            "WHERE id = ? AND status = 'pending'",
            (rid,),
        )
        return cur.rowcount > 0
