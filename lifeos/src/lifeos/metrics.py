"""Fast-path instrumentation for the chat ingestion pipeline.

Records WHERE each chat call was handled (which fast-path branch matched,
or whether it fell through to the brain) + how long it took. Used to
answer the empirical question:

    "Is the chat fast-path good enough, or do we need nano-agents?"

Privacy: this table lives in the UNENCRYPTED core lifeos.db because it
stores only metadata — stage name, latency, text length (char count),
has_image flag. The actual text content is NEVER stored here. The text
lives in each domain's encrypted store or in the chat memory.

Public surface:
    record(stage, latency_ms, text_length, has_image=False)
    summary(days=7)             → per-stage counts + latency stats
    list_recent(days=1, limit=100) → raw rows for debugging
    clear()                     → wipe (for tests)
"""

from __future__ import annotations

import logging
import statistics
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import ulid

from lifeos import store

log = logging.getLogger("lifeos.metrics")


# All possible values of `stage`. Used both for type hints and for
# pre-computed zero rows in summaries (so a stage with 0 hits still
# appears in the table for context).
KNOWN_STAGES = (
    "purchase_consult",
    "events",
    "learning",
    "spirituality",
    "exercise",
    "relationships",
    "health",
    "finance",
    "reminders",
    "brain",        # fell through everything → big brain handled it
    "image_only",   # message was just an image; brain handled
    "empty",        # empty input — rejected early
    "error",        # something crashed; tracked anyway
)


@dataclass(frozen=True, slots=True)
class Metric:
    id: str
    ts: datetime
    stage: str
    latency_ms: int
    text_length: int
    has_image: bool


def _to_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    if "T" in s:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def record(*, stage: str, latency_ms: int, text_length: int = 0,
           has_image: bool = False) -> None:
    """Insert one metric row. Designed to NEVER raise — even if storage
    is broken, the chat call shouldn't fail because metrics did."""
    try:
        with store.connect() as conn:
            conn.execute(
                "INSERT INTO fastpath_metrics(id, ts, stage, latency_ms, "
                "text_length, has_image) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    str(ulid.new()),
                    _to_iso_utc(datetime.now(timezone.utc)),
                    str(stage),
                    int(latency_ms),
                    int(text_length),
                    1 if has_image else 0,
                ),
            )
    except Exception as e:  # noqa: BLE001
        log.warning("metrics.record failed: %s", e)


def list_recent(*, days: int = 1, limit: int = 200) -> list[Metric]:
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT * FROM fastpath_metrics WHERE ts >= datetime('now', ?) "
            "ORDER BY ts DESC LIMIT ?",
            (f"-{int(days)} days", int(limit)),
        ).fetchall()
    return [
        Metric(
            id=r["id"],
            ts=_parse_iso(r["ts"]),
            stage=r["stage"],
            latency_ms=int(r["latency_ms"]),
            text_length=int(r["text_length"]),
            has_image=bool(r["has_image"]),
        )
        for r in rows
    ]


def summary(*, days: int = 7) -> dict[str, Any]:
    """Aggregated stats over the last `days` days.

    Returns a dict with:
      total: int
      brain_fallback_pct: float  (% of calls that ended at 'brain')
      by_stage: list[ {stage, count, pct, latency_ms_p50, latency_ms_p95,
                       avg_text_length} ]  sorted by count DESC
      latency_overall: {p50, p95, mean}
    """
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT stage, latency_ms, text_length, has_image FROM fastpath_metrics "
            "WHERE ts >= datetime('now', ?)",
            (f"-{int(days)} days",),
        ).fetchall()
    if not rows:
        return {
            "total": 0,
            "brain_fallback_pct": 0.0,
            "by_stage": [],
            "latency_overall": {"p50": 0, "p95": 0, "mean": 0},
            "window_days": days,
        }

    total = len(rows)
    by_stage_buckets: dict[str, list[dict]] = {}
    for r in rows:
        by_stage_buckets.setdefault(r["stage"], []).append({
            "latency_ms": int(r["latency_ms"]),
            "text_length": int(r["text_length"]),
        })

    by_stage = []
    all_latencies: list[int] = []
    for stage, bucket in by_stage_buckets.items():
        latencies = [b["latency_ms"] for b in bucket]
        text_lens = [b["text_length"] for b in bucket]
        all_latencies.extend(latencies)
        by_stage.append({
            "stage": stage,
            "count": len(bucket),
            "pct": round(len(bucket) / total * 100, 1),
            "latency_ms_p50": int(statistics.median(latencies)),
            "latency_ms_p95": _percentile(latencies, 95),
            "latency_ms_mean": int(statistics.mean(latencies)),
            "avg_text_length": int(statistics.mean(text_lens)) if text_lens else 0,
        })
    by_stage.sort(key=lambda x: x["count"], reverse=True)

    brain_count = by_stage_buckets.get("brain", [])
    brain_pct = round(len(brain_count) / total * 100, 1) if brain_count else 0.0

    return {
        "total": total,
        "brain_fallback_pct": brain_pct,
        "by_stage": by_stage,
        "latency_overall": {
            "p50": int(statistics.median(all_latencies)),
            "p95": _percentile(all_latencies, 95),
            "mean": int(statistics.mean(all_latencies)),
        },
        "window_days": days,
    }


def _percentile(values: list[int], p: int) -> int:
    if not values:
        return 0
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return int(s[f] + (s[c] - s[f]) * (k - f))


def clear() -> None:
    """Wipe all metrics. Mostly for tests."""
    with store.connect() as conn:
        conn.execute("DELETE FROM fastpath_metrics")
