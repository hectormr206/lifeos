"""DAO for the finance domain.

Kinds:
    expense        — outflow (cafe, groceries, gas, subscriptions, …)
    big_purchase   — outflow above a "decision" threshold; auto-schedules
                      a +7d reflection on impulsivity.
    debt_payment   — outflow that pays down a debt.
    income         — inflow (salary, freelance, bonus, …).
    savings        — money moved into long-term savings (positive amount;
                      treated as inflow from the saver's POV).
    note           — free-form annotation, amount=0 by default.

Amounts are non-negative; `kind` determines flow direction.

Reflection loop:
    On `kind='big_purchase'`, if no `reflect_at` is supplied, default to
    `when + 7 days`. The dashboard's pending_reflections() returns rows
    where reflect_at <= now AND reflection_done = 0 so the UI can nudge.
    `mark_reflected(id, tag)` accepts 'impulsive' or 'planned' and flips
    the flag.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

import ulid

from lifeos.finance import store

Kind = Literal["expense", "income", "savings", "debt_payment", "big_purchase", "note"]
Source = Literal["manual", "chat", "voice"]
_VALID_KINDS = {"expense", "income", "savings", "debt_payment", "big_purchase", "note"}
_REFLECT_TAGS = {"impulsive", "planned"}

# Big purchases default to a 7-day reflection window. Configurable later.
_DEFAULT_REFLECT_DAYS = 7


@dataclass(frozen=True, slots=True)
class Entry:
    id: str
    ts: datetime
    kind: Kind
    amount: float
    currency: str
    category: str | None
    merchant: str | None
    title: str
    body: str | None
    tags: list[str] = field(default_factory=list)
    source: Source = "manual"
    confidence: float = 1.0
    reflect_at: datetime | None = None
    reflection_done: bool = False
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
    tags = [t for t in (row["tags"] or "").split(",") if t]
    keys = row.keys() if hasattr(row, "keys") else []
    return Entry(
        id=row["id"],
        ts=_parse_iso(row["ts"]),
        kind=row["kind"],
        amount=float(row["amount"]),
        currency=row["currency"],
        category=row["category"],
        merchant=row["merchant"],
        title=row["title"],
        body=row["body"],
        tags=tags,
        source=row["source"],
        confidence=float(row["confidence"]),
        reflect_at=_parse_iso(row["reflect_at"]) if row["reflect_at"] else None,
        reflection_done=bool(row["reflection_done"]),
        reminder_id=row["reminder_id"],
        created_at=_parse_iso(row["created_at"]) if row["created_at"] else None,
        deleted_at=_parse_iso(row["deleted_at"]) if row["deleted_at"] else None,
        raw_utterance=row["raw_utterance"] if "raw_utterance" in keys else None,
        source_conv_id=row["source_conv_id"] if "source_conv_id" in keys else None,
    )


def create(*, kind: Kind, title: str, amount: float, when: datetime,
           currency: str = "MXN",
           category: str | None = None,
           merchant: str | None = None,
           body: str | None = None,
           tags: list[str] | None = None,
           source: Source = "manual",
           confidence: float = 1.0,
           reflect_at: datetime | None = None,
           reminder_id: str | None = None,
           raw_utterance: str | None = None,
           source_conv_id: int | None = None) -> Entry:
    """Insert a new finance entry.

    For `kind='big_purchase'` and `reflect_at` omitted, automatically sets
    `reflect_at = when + 7 days` so the reflection loop kicks in.
    """
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    if amount < 0:
        raise ValueError("amount must be non-negative (kind decides direction)")
    if reflect_at is not None and reflect_at.tzinfo is None:
        raise ValueError("reflect_at must be tz-aware")

    if kind == "big_purchase" and reflect_at is None:
        reflect_at = when + timedelta(days=_DEFAULT_REFLECT_DAYS)

    eid = str(ulid.new())
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO finance_entries"
            "(id, ts, kind, amount, currency, category, merchant, title, body, "
            " tags, source, confidence, reflect_at, reminder_id, "
            " raw_utterance, source_conv_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                eid, _to_iso_utc(when), kind, float(amount), currency,
                category, merchant, title, body,
                ",".join(tags) if tags else None,
                source, float(confidence),
                _to_iso_utc(reflect_at) if reflect_at else None,
                reminder_id,
                raw_utterance, source_conv_id,
            ),
        )
    fetched = get(eid)
    assert fetched is not None
    return fetched


def update(
    eid: str,
    *,
    kind: Kind,
    title: str,
    amount: float,
    when: datetime,
    currency: str = "MXN",
    category: str | None = None,
    merchant: str | None = None,
    body: str | None = None,
    tags: list[str] | None = None,
) -> Entry | None:
    """Update a non-deleted finance entry.

    Returns the updated Entry, or None if no active row matched (the entry
    does not exist or has been soft-deleted). Raises ValueError for invalid
    kind, naive datetimes, or negative amounts (mirrors create()).

    Note: source and confidence are immutable provenance, and the reflection
    loop state (reflect_at, reflection_done, reminder_id) is owned by the
    big-purchase flow — none of those are editable here.
    """
    if kind not in _VALID_KINDS:
        raise ValueError(f"kind must be one of {_VALID_KINDS}, got {kind!r}")
    if when.tzinfo is None:
        raise ValueError("when must be tz-aware (got naive datetime)")
    if amount < 0:
        raise ValueError("amount must be non-negative (kind decides direction)")
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE finance_entries "
            "SET ts=?, kind=?, amount=?, currency=?, category=?, merchant=?, "
            "    title=?, body=?, tags=? "
            "WHERE id=? AND deleted_at IS NULL",
            (
                _to_iso_utc(when),
                kind,
                float(amount),
                currency,
                category,
                merchant,
                title,
                body,
                ",".join(tags) if tags else None,
                eid,
            ),
        )
        if cur.rowcount == 0:
            return None
    return get(eid)


def get(eid: str, *, include_deleted: bool = False) -> Entry | None:
    with store.connect() as conn:
        if include_deleted:
            row = conn.execute(
                "SELECT * FROM finance_entries WHERE id = ?", (eid,)
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM finance_entries WHERE id = ? AND deleted_at IS NULL",
                (eid,),
            ).fetchone()
    return _row_to_entry(row) if row else None


def list_recent(*, days: int = 30, kind: Kind | None = None,
                limit: int = 500) -> list[Entry]:
    q = (
        "SELECT * FROM finance_entries WHERE deleted_at IS NULL "
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
        "SELECT * FROM finance_entries WHERE deleted_at IS NULL "
        "AND (title LIKE ? OR body LIKE ? OR merchant LIKE ?)"
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


def pending_reflections() -> list[Entry]:
    """Big-purchase entries whose reflect_at is past and not yet classified."""
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM finance_entries "
            "WHERE deleted_at IS NULL "
            "AND reflect_at IS NOT NULL "
            "AND reflection_done = 0 "
            "AND reflect_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "ORDER BY reflect_at ASC"
        ).fetchall()
    return [_row_to_entry(r) for r in rows]


def mark_reflected(eid: str, *, tag: str) -> None:
    """Mark a big-purchase as reflected with either 'impulsive' or 'planned'."""
    if tag not in _REFLECT_TAGS:
        raise ValueError(f"tag must be one of {_REFLECT_TAGS}, got {tag!r}")
    with store.connect() as conn:
        row = conn.execute(
            "SELECT tags FROM finance_entries WHERE id = ?", (eid,)
        ).fetchone()
        if row is None:
            return
        existing = {t for t in (row["tags"] or "").split(",") if t}
        existing.add(tag)
        new_tags = ",".join(sorted(existing))
        conn.execute(
            "UPDATE finance_entries SET tags = ?, reflection_done = 1 WHERE id = ?",
            (new_tags, eid),
        )


def summary(*, days: int = 30) -> dict[str, float]:
    """Return totals per kind over the last `days` days."""
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT kind, SUM(amount) as total FROM finance_entries "
            "WHERE deleted_at IS NULL AND ts >= datetime('now', ?) "
            "GROUP BY kind",
            (f"-{int(days)} days",),
        ).fetchall()
    out = {
        "expenses_total": 0.0,
        "income_total": 0.0,
        "savings_total": 0.0,
        "debt_payments_total": 0.0,
        "big_purchases_total": 0.0,
    }
    bucket = {
        "expense": "expenses_total",
        "income": "income_total",
        "savings": "savings_total",
        "debt_payment": "debt_payments_total",
        "big_purchase": "big_purchases_total",
    }
    for r in rows:
        key = bucket.get(r["kind"])
        if key:
            out[key] = float(r["total"] or 0)
    return out


def delete(eid: str) -> bool:
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE finance_entries SET deleted_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') "
            "WHERE id = ? AND deleted_at IS NULL",
            (eid,),
        )
        return cur.rowcount > 0


def update_title(eid: str, title: str) -> bool:
    """Update only the title of a non-deleted finance entry."""
    with store.connect() as conn:
        cur = conn.execute(
            "UPDATE finance_entries SET title=? WHERE id=? AND deleted_at IS NULL",
            (title, eid),
        )
        return cur.rowcount > 0
