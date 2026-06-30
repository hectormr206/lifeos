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
    recurrence: str | None = None
    last_fired_at: datetime | None = None
    ends_at: datetime | None = None
    occurrences_left: int | None = None
    action_kind: str = "message"
    action_prompt: str | None = None
    last_result: str | None = None
    last_result_at: datetime | None = None
    last_result_meta: str | None = None

    @property
    def is_recurring(self) -> bool:
        return bool(self.recurrence)

    @property
    def is_agentic(self) -> bool:
        return self.action_kind == "agentic"


def _row_to_reminder(row) -> Reminder:
    keys = row.keys()
    return Reminder(
        id=row["id"],
        when_ts=_parse_iso(row["when_ts"]),
        message=row["message"],
        channel=row["channel"],
        status=row["status"],
        created_at=_parse_iso(row["created_at"]),
        fired_at=_parse_iso(row["fired_at"]) if row["fired_at"] else None,
        error=row["error"],
        recurrence=row["recurrence"] if "recurrence" in keys else None,
        last_fired_at=(
            _parse_iso(row["last_fired_at"])
            if "last_fired_at" in keys and row["last_fired_at"]
            else None
        ),
        ends_at=(
            _parse_iso(row["ends_at"])
            if "ends_at" in keys and row["ends_at"]
            else None
        ),
        occurrences_left=(
            row["occurrences_left"]
            if "occurrences_left" in keys and row["occurrences_left"] is not None
            else None
        ),
        action_kind=(
            row["action_kind"]
            if "action_kind" in keys and row["action_kind"]
            else "message"
        ),
        action_prompt=(
            row["action_prompt"] if "action_prompt" in keys else None
        ),
        last_result=row["last_result"] if "last_result" in keys else None,
        last_result_at=(
            _parse_iso(row["last_result_at"])
            if "last_result_at" in keys and row["last_result_at"]
            else None
        ),
        last_result_meta=(
            row["last_result_meta"] if "last_result_meta" in keys else None
        ),
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


def create(*, when: datetime, message: str, channel: Channel = "push",
           recurrence: str | None = None,
           ends_at: datetime | None = None,
           occurrences_left: int | None = None,
           action_kind: str = "message",
           action_prompt: str | None = None) -> Reminder:
    """Insert a new pending reminder.

    Optional end conditions for recurring reminders:
      - `ends_at`: scheduler stops firing after this instant.
      - `occurrences_left`: countdown of remaining fires.
    Both are mutually compatible (whichever hits first wins).

    Agentic reminders (Briefings):
      - `action_kind='agentic'` + `action_prompt`: when the reminder fires,
        the dispatcher runs the prompt through the brain with web-search
        tools and stores the curated result on the row.
    """
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    if ends_at is not None and ends_at.tzinfo is None:
        raise ValueError("ends_at must be tz-aware")
    if action_kind not in ("message", "agentic"):
        raise ValueError("action_kind must be 'message' or 'agentic'")
    rid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO reminders(id, when_ts, message, channel, status, "
            "recurrence, ends_at, occurrences_left, action_kind, action_prompt) "
            "VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)",
            (
                rid, _to_iso_utc(when), message, channel, recurrence,
                _to_iso_utc(ends_at) if ends_at else None,
                occurrences_left, action_kind, action_prompt,
            ),
        )
    fetched = get(rid)
    assert fetched is not None
    return fetched


def set_last_result(rid: str, *, result: str, meta: str | None = None) -> None:
    """Store the latest agentic-briefing result on a reminder row.

    Overwrites the previous result (cards show the LATEST run only) and
    stamps `last_result_at` with the current UTC instant. `meta` is a JSON
    string of structured items so the card can render title/summary/url.
    """
    with store.connect() as conn:
        conn.execute(
            "UPDATE reminders SET last_result = ?, last_result_meta = ?, "
            "last_result_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ?",
            (result, meta, rid),
        )


def list_agentic() -> list[Reminder]:
    """All non-cancelled agentic reminders, newest activity first.

    Used by the Briefings dashboard: one card per agentic reminder. Cancelled
    reminders are excluded so a deleted (soft-cancelled) task stops showing.
    """
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM reminders WHERE action_kind = 'agentic' "
            "AND status != 'cancelled' "
            "ORDER BY COALESCE(last_result_at, when_ts) DESC"
        ).fetchall()
    return [_row_to_reminder(r) for r in rows]


def mark_recurring_fired(rid: str) -> None:
    """Bump last_fired_at for a recurring reminder. Keeps status=pending."""
    with store.connect() as conn:
        conn.execute(
            "UPDATE reminders SET last_fired_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ?",
            (rid,),
        )


def decrement_occurrences(rid: str) -> int | None:
    """Decrement `occurrences_left` by 1 and return the new value.

    Returns None if the reminder has no occurrences_left set (unbounded).
    Returns 0 when the last allowed firing has just happened — the caller
    should then mark the reminder cancelled and remove the apscheduler job.
    """
    with store.connect() as conn:
        row = conn.execute(
            "SELECT occurrences_left FROM reminders WHERE id = ?", (rid,)
        ).fetchone()
        if row is None or row["occurrences_left"] is None:
            return None
        new_count = max(0, int(row["occurrences_left"]) - 1)
        conn.execute(
            "UPDATE reminders SET occurrences_left = ? WHERE id = ?",
            (new_count, rid),
        )
        return new_count


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
    """Mark a ONE-SHOT reminder as fired (terminal). Sets both fired_at
    and last_fired_at to now."""
    with store.connect() as conn:
        conn.execute(
            "UPDATE reminders SET status='fired', "
            "fired_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), "
            "last_fired_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
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


def update(
    rid: str,
    *,
    when: datetime,
    message: str,
    channel: Channel,
    recurrence: str | None = None,
    ends_at: datetime | None = None,
    occurrences_left: int | None = None,
) -> "Reminder | None":
    """Update a PENDING reminder.

    Returns the updated Reminder, or None if no pending row matched (e.g.
    the reminder was already fired/cancelled, or does not exist).
    Raises ValueError for naive datetimes (mirrors create()).
    """
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    if ends_at is not None and ends_at.tzinfo is None:
        raise ValueError("ends_at must be tz-aware")
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE reminders "
            "SET when_ts=?, message=?, channel=?, recurrence=?, "
            "    ends_at=?, occurrences_left=? "
            "WHERE id=? AND status='pending'",
            (
                _to_iso_utc(when),
                message,
                channel,
                recurrence,
                _to_iso_utc(ends_at) if ends_at else None,
                occurrences_left,
                rid,
            ),
        )
        if cur.rowcount == 0:
            return None
    return get(rid)
