"""Daily digest builder (PRD P1.3).

Aggregates counts and key facts for "today" in the user's timezone. Endpoint
is read-only and cheap — pure SQLite scans plus an optional brain call when
`digest_brain_enabled` is True. Brain output is cached in-memory for 1 hour
keyed by the local date.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from datetime import datetime, time as dt_time
from typing import Any
from zoneinfo import ZoneInfo

log = logging.getLogger("axi.digest")

_summary_cache: dict[str, tuple[float, str]] = {}
_summary_lock = threading.Lock()
_SUMMARY_TTL_S = 3600


def _tz() -> ZoneInfo:
    from axi import config
    name = config.get("timezone", "America/Mexico_City")
    try:
        return ZoneInfo(name)
    except Exception:  # noqa: BLE001
        return ZoneInfo("America/Mexico_City")


def _today_bounds(now: float | None = None) -> tuple[float, float, str]:
    """Return (start_ts, end_ts, iso_date) for the current local day."""
    tz = _tz()
    if now is None:
        now = time.time()
    now_local = datetime.fromtimestamp(now, tz=tz)
    start_local = datetime.combine(now_local.date(), dt_time.min, tzinfo=tz)
    end_local = datetime.combine(now_local.date(), dt_time.max, tzinfo=tz)
    return start_local.timestamp(), end_local.timestamp(), now_local.strftime("%Y-%m-%d")


def _count_conversations(c, start_ts: float, end_ts: float) -> int:
    row = c.execute(
        "SELECT COUNT(*) AS n FROM conversations WHERE ts >= ? AND ts <= ?",
        (start_ts, end_ts),
    ).fetchone()
    return int(row["n"]) if row else 0


def _count_meetings(c, start_ts: float, end_ts: float) -> int:
    row = c.execute(
        "SELECT COUNT(*) AS n FROM meetings WHERE created_at >= ? AND created_at <= ?",
        (start_ts, end_ts),
    ).fetchone()
    return int(row["n"]) if row else 0


def _facts_today(c, start_ts: float, end_ts: float, limit: int = 10) -> list[dict[str, Any]]:
    # Subject attribution: the daily digest is the USER's OWN summary, so
    # family-subject facts (data carries a "subject" key) are excluded. The SQL
    # LIKE keeps the LIMIT honest; the parsed-data check below is the precise
    # gate (a non-empty data.subject → belongs to a family member, skip).
    rows = c.execute(
        "SELECT id, label, domain, data, created_at FROM nodes "
        "WHERE kind = 'fact' AND created_at >= ? AND created_at <= ? "
        "AND (data IS NULL OR data NOT LIKE '%\"subject\"%') "
        "ORDER BY created_at ASC LIMIT ?",
        (start_ts, end_ts, limit),
    ).fetchall()
    out = []
    for r in rows:
        try:
            data = json.loads(r["data"] or "{}")
        except json.JSONDecodeError:
            data = {}
        subject = data.get("subject")
        if isinstance(subject, str) and subject.strip():
            continue  # family member's fact — not part of the user's own digest
        out.append({
            "id": r["id"],
            "label": r["label"],
            "domain": r["domain"],
            "category": data.get("category"),
            "ts": r["created_at"],
        })
    return out


def _count_events_at_levels(c, start_ts: float, end_ts: float) -> tuple[int, int]:
    rows = c.execute(
        "SELECT level, COUNT(*) AS n FROM events "
        "WHERE ts >= ? AND ts <= ? AND level IN ('critical','error') "
        "GROUP BY level",
        (start_ts, end_ts),
    ).fetchall()
    crit = 0
    err = 0
    for r in rows:
        if r["level"] == "critical":
            crit = int(r["n"])
        elif r["level"] == "error":
            err = int(r["n"])
    return crit, err


def _maybe_brain_summary(
    iso_date: str,
    convs: int,
    meets: int,
    facts: int,
    top_facts: list[dict[str, Any]],
    brain_ask=None,
    brain_alive=None,
) -> str | None:
    from axi import config
    if not bool(config.get("digest_brain_enabled", False)):
        return None
    # Cache
    with _summary_lock:
        hit = _summary_cache.get(iso_date)
        if hit and (time.time() - hit[0]) < _SUMMARY_TTL_S:
            return hit[1]
    # Lazy import so tests can monkeypatch easily.
    if brain_ask is None or brain_alive is None:
        try:
            from axi import brain  # noqa: PLC0415
            brain_ask = brain.ask
            brain_alive = brain.is_alive
        except Exception:  # noqa: BLE001
            return None
    try:
        if not brain_alive():
            return None
    except Exception:  # noqa: BLE001
        return None
    facts_str = "; ".join(f["label"] for f in top_facts[:5]) or "ninguno"
    prompt = (
        "Resume el día de Héctor en 2-3 oraciones en español natural usando estos datos: "
        f"{convs} conversaciones, {meets} reuniones, {facts} hechos nuevos. "
        f"Hechos relevantes: {facts_str}."
    )
    try:
        text = brain_ask(prompt, max_tokens=200, timeout=30.0, task="narration")
    except Exception as e:  # noqa: BLE001
        log.warning("digest brain call failed: %s", e)
        return None
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    with _summary_lock:
        _summary_cache[iso_date] = (time.time(), text)
    return text


def build_today(brain_ask=None, brain_alive=None, now: float | None = None) -> dict[str, Any]:
    """Return the daily digest dict for today (local time)."""
    from axi import store
    start_ts, end_ts, iso_date = _today_bounds(now=now)
    c = store._connect()  # noqa: SLF001
    convs = _count_conversations(c, start_ts, end_ts)
    meets = _count_meetings(c, start_ts, end_ts)
    top_facts = _facts_today(c, start_ts, end_ts, limit=10)
    crit, err = _count_events_at_levels(c, start_ts, end_ts)
    summary = _maybe_brain_summary(
        iso_date, convs, meets, len(top_facts), top_facts,
        brain_ask=brain_ask, brain_alive=brain_alive,
    )
    return {
        "date": iso_date,
        "conversations_count": convs,
        "meetings_count": meets,
        "facts_added_count": len(top_facts),
        "events_critical_count": crit,
        "events_error_count": err,
        "top_facts": top_facts,
        "generated_summary": summary,
    }


def _clear_cache_for_tests() -> None:
    with _summary_lock:
        _summary_cache.clear()
