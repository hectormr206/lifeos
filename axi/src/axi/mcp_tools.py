"""Pure tool implementations exposed over MCP (T2).

Each function maps a single LifeOS capability to JSON-serialisable output by
calling the existing domain APIs directly (no HTTP). Kept free of any MCP
runtime import so it stays trivially testable; ``axi.mcp_server`` registers
these with FastMCP.

Scope (v1): reads + additive writes only. There are deliberately no
destructive operations (no delete/clear/config writes).
"""
from __future__ import annotations

from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from typing import Any

from axi import store


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _parse_when(when_iso: str | None) -> datetime:
    """Parse an ISO-8601 string to a tz-aware datetime (defaults to now, UTC).

    Naive inputs are assumed UTC — the domain APIs reject naive datetimes.
    """
    if not when_iso:
        return _now_utc()
    dt = datetime.fromisoformat(when_iso)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _jsonable(obj: Any) -> Any:
    """Recursively convert dataclasses/datetimes into JSON-safe values."""
    if is_dataclass(obj) and not isinstance(obj, type):
        obj = asdict(obj)
    if isinstance(obj, dict):
        return {k: _jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_jsonable(v) for v in obj]
    if isinstance(obj, datetime):
        return obj.isoformat()
    return obj


# ─────────────────────────────── reads ───────────────────────────────

def memory_search(query: str, limit: int = 10) -> list[dict]:
    """Full-text search over the assistant's knowledge graph (facts, people,
    events). Returns matching nodes."""
    return [dict(r) for r in store.search_nodes_fts(query, limit=limit)]


def recent_conversations(limit: int = 20) -> list[dict]:
    """Return the most recent chat turns with the assistant, oldest first."""
    return [dict(r) for r in store.recent_conversations(limit=limit)]


def list_reminders(status: str = "pending") -> list[dict]:
    """List reminders. status='pending' (default) returns active ones;
    anything else returns recent reminders from the last 30 days."""
    from lifeos import reminders
    items = reminders.list_pending() if status == "pending" else reminders.list_recent()
    return [_jsonable(r) for r in items]


def finance_summary(days: int = 30) -> dict:
    """Aggregate finance totals (by kind) over the last *days* days."""
    from lifeos.finance import entries as fin
    return fin.summary(days=days)


def health_recent(days: int = 30, limit: int = 50) -> list[dict]:
    """Return recent health entries (symptoms, medications, vitals, …)."""
    from lifeos.health import entries as he
    return [_jsonable(e) for e in he.list_recent(days=days)[:limit]]


# ────────────────────────── writes (additive) ──────────────────────────

def add_fact(label: str, data: dict | None = None, domain: str | None = None) -> dict:
    """Store a new fact in the assistant's long-term memory. Returns its id."""
    nid = store.add_node("fact", label, data=data, domain=domain)
    return {"id": nid, "label": label}


def create_reminder(message: str, when_iso: str | None = None) -> dict:
    """Create a reminder. when_iso is ISO-8601 (e.g. '2026-12-01T09:00:00+00:00');
    omit it to schedule for now."""
    from lifeos import reminders
    return _jsonable(reminders.create(when=_parse_when(when_iso), message=message))


def log_finance_entry(
    kind: str,
    title: str,
    amount: float,
    when_iso: str | None = None,
    currency: str = "MXN",
) -> dict:
    """Record a finance entry. kind is one of expense|income|savings|
    debt_payment|big_purchase|note. amount must be non-negative."""
    from lifeos.finance import entries as fin
    entry = fin.create(
        kind=kind, title=title, amount=amount,
        when=_parse_when(when_iso), currency=currency,
    )
    try:
        from axi import domain_bridge as _db
        _db.bridge_entry("finance", entry)
    except Exception:  # noqa: BLE001
        pass
    return _jsonable(entry)


def log_health_entry(
    kind: str,
    title: str,
    when_iso: str | None = None,
    body: str | None = None,
) -> dict:
    """Record a health entry. kind is one of symptom|medication|vital|
    condition|note."""
    from lifeos.health import entries as he
    entry = he.create(kind=kind, title=title, when=_parse_when(when_iso), body=body)
    try:
        from axi import domain_bridge as _db
        _db.bridge_entry("health", entry)
    except Exception:  # noqa: BLE001
        pass
    return _jsonable(entry)
