"""Correlation Engine — bundle active life-context for decision callers.

Unifies three previously siloed pieces:
  * `lifeos.insights.patterns` — active behavioral patterns.
  * `lifeos.edges` — cross-domain graph relations.
  * `lifeos.decide.*` — consumers that need this context in their prompts.

Public surface:
    build_bundle(*, db=None, now=None, domain_hint=None) → CorrelationBundle
    render_summary(patterns_list, edges_list) → str
    register(scheduler) — add the hourly correlation_snapshot job.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from apscheduler.schedulers.background import BackgroundScheduler

log = logging.getLogger("lifeos.insights.correlate")

# ─── Sleep → spending correlation constants ───────────────────────────────────

_WINDOW_DAYS = 90
_LAG_DAYS = 2
_SLEEP_THRESHOLD = 6.5
_MIN_RATE_RATIO = 2.0
_MIN_POOR_SLEEP_DAYS = 3
_MIN_TOTAL_IMPULSIVE = 2
_OK_RATE_FLOOR = 0.001
_TTL_DAYS = 7


@dataclass(frozen=True)
class CorrelationResult:
    """Metrics produced by the sleep → impulsive-spending detector."""

    rate_ratio: float
    poor_sleep_days: int
    ok_sleep_days: int
    impulsive_after_poor: int
    impulsive_after_ok: int
    total_impulsive: int
    window_days: int
    lag_days: int
    threshold: float


# ─── Sleep → spending detector ───────────────────────────────────────────────


def _bucket_sleep_by_day(sleep_entries) -> dict:
    """Return {date: min_hours} from a list of sleep vital entries."""
    from datetime import date as _date

    result: dict = {}
    for e in sleep_entries:
        if e.data.get("type") != "sleep_hours":
            continue
        hours = float(e.data.get("value", 0))
        day = e.ts.astimezone(timezone.utc).date()
        if day not in result or hours < result[day]:
            result[day] = hours
    return result


def _impulsive_purchase_days(finance_entries) -> set:
    """Return the set of UTC dates that have at least one impulsive purchase."""
    days: set = set()
    for e in finance_entries:
        if "impulsive" in (e.tags or []):
            days.add(e.ts.astimezone(timezone.utc).date())
    return days


def _detect_sleep_spending_correlation(
    now: datetime,
    *,
    health_list_recent=None,
    finance_list_recent=None,
) -> "CorrelationResult | None":
    """Pure detector: read sleep + impulsive-purchase data, apply heuristic.

    Returns a CorrelationResult when all three guards pass, otherwise None.
    Never touches the graph.  Inject `health_list_recent` / `finance_list_recent`
    callables for unit testing; defaults use the real DAOs.
    """
    if health_list_recent is None:
        from lifeos.health import entries as health_entries  # noqa: PLC0415
        health_list_recent = health_entries.list_recent

    if finance_list_recent is None:
        from lifeos.finance import entries as finance_entries  # noqa: PLC0415
        finance_list_recent = finance_entries.list_recent

    sleep_raw = health_list_recent(days=_WINDOW_DAYS, kind="vital")
    finance_raw = finance_list_recent(days=_WINDOW_DAYS, kind="big_purchase")

    sleep_by_day = _bucket_sleep_by_day(sleep_raw)
    impulsive_days = _impulsive_purchase_days(finance_raw)

    if not sleep_by_day:
        return None

    # Classify each sleep day
    poor_sleep_days = sum(1 for h in sleep_by_day.values() if h < _SLEEP_THRESHOLD)
    ok_sleep_days = len(sleep_by_day) - poor_sleep_days
    total_impulsive = len(impulsive_days)

    # Early guards — avoid needless computation
    if poor_sleep_days < _MIN_POOR_SLEEP_DAYS:
        return None
    # NOTE: total_impulsive counts ALL impulsive-purchase days in the full 90-day window
    # (via len(impulsive_days)), not only those that fall within a lag window after a
    # poor-sleep day.  This is intentional: it's a cheap pre-filter that avoids the O(n)
    # lag-match loop when spending data is sparse.  The rate_ratio guard is the
    # load-bearing signal that captures the directional relationship.
    if total_impulsive < _MIN_TOTAL_IMPULSIVE:
        return None

    # Lag match: count poor/ok days that have an impulsive purchase within lag window
    from datetime import timedelta as _td  # noqa: PLC0415

    impulsive_after_poor = 0
    impulsive_after_ok = 0
    for day, hours in sleep_by_day.items():
        matched = any(
            (day + _td(days=lag)) in impulsive_days
            for lag in range(_LAG_DAYS + 1)  # 0, 1, 2
        )
        if hours < _SLEEP_THRESHOLD:
            if matched:
                impulsive_after_poor += 1
        else:
            if matched:
                impulsive_after_ok += 1

    rate_after_poor = impulsive_after_poor / poor_sleep_days
    rate_after_ok = impulsive_after_ok / ok_sleep_days if ok_sleep_days > 0 else 0.0
    rate_ratio = rate_after_poor / max(rate_after_ok, _OK_RATE_FLOOR)

    if rate_ratio < _MIN_RATE_RATIO:
        return None

    return CorrelationResult(
        rate_ratio=rate_ratio,
        poor_sleep_days=poor_sleep_days,
        ok_sleep_days=ok_sleep_days,
        impulsive_after_poor=impulsive_after_poor,
        impulsive_after_ok=impulsive_after_ok,
        total_impulsive=total_impulsive,
        window_days=_WINDOW_DAYS,
        lag_days=_LAG_DAYS,
        threshold=_SLEEP_THRESHOLD,
    )


# ─── Persist step ────────────────────────────────────────────────────────────


def _persist_correlation_edge(
    result: "CorrelationResult",
    now: datetime,
    *,
    edges_mod=None,
) -> "Edge":
    """Dedup-then-write a single correlates-with edge.

    Deletes any existing edge with matching src/dst before creating the fresh one.
    Accepts an injectable `edges_mod` for unit tests.
    """
    if edges_mod is None:
        from lifeos import edges as _edges  # noqa: PLC0415
        edges_mod = _edges

    # Dedup: remove any stale matching edge
    for e in edges_mod.by_relation(
        "correlates-with",
        src_domain="health",
        dst_domain="finance",
        limit=200,
    ):
        if e.src_id == "sleep_deficit_pattern" and e.dst_id == "impulsive_spending":
            edges_mod.delete(e.id)

    expires_at = (now + timedelta(days=_TTL_DAYS)).isoformat()
    ratio = result.rate_ratio
    note = (
        f"Compras impulsivas {ratio:.1f}× más frecuentes tras noches de mal "
        f"sueño (<6.5h), basado en {result.poor_sleep_days} días de sueño deficiente."
    )

    return edges_mod.create(
        src=("health", "sleep_deficit_pattern"),
        dst=("finance", "impulsive_spending"),
        rel="correlates-with",
        metadata={
            "strength": round(ratio, 2),
            "rate_ratio": round(ratio, 2),
            "window_days": result.window_days,
            "lag_days": result.lag_days,
            "poor_sleep_days": result.poor_sleep_days,
            "impulsive_after_poor": result.impulsive_after_poor,
            "total_impulsive": result.total_impulsive,
            "threshold": result.threshold,
            "expires_at": expires_at,
            "snapshot": True,
            "note": note,
        },
        created_by="correlation_snapshot",
    )


# ─── Data contract ────────────────────────────────────────────────────────────


@dataclass
class CorrelationBundle:
    """Snapshot of active life-context ready for injection into decision prompts."""

    active_patterns: list = field(default_factory=list)   # list[Pattern]
    relevant_edges: list = field(default_factory=list)    # list[Edge]
    edge_summary: str = ""                                # Spanish prose, empty when nothing active


# ─── Helpers ─────────────────────────────────────────────────────────────────


def _severity_label(severity: str) -> str:
    labels = {"warning": "⚠️ advertencia", "critical": "🚨 crítico", "info": "ℹ️ info"}
    return labels.get(severity, severity)


def _pattern_line(p) -> str:
    """One-liner Spanish description of a Pattern."""
    return f"{p.message} ({p.kind}, severidad: {p.severity})"


def _edge_line(e) -> str:
    """One-liner for an Edge, used in the graph section."""
    md = e.metadata or {}
    note = md.get("note", "")
    if note:
        return f"{e.src_domain}:{e.src_id} —[{e.rel}]→ {e.dst_domain}:{e.dst_id} · {note}"
    return f"{e.src_domain}:{e.src_id} —[{e.rel}]→ {e.dst_domain}:{e.dst_id}"


# ─── Core ─────────────────────────────────────────────────────────────────────


def render_summary(patterns_list: list, edges_list: list) -> str:
    """Render a compact Spanish summary ready to inject into a prompt.

    Returns an empty string when there is nothing to report — callers can
    concatenate without a guard.
    """
    if not patterns_list and not edges_list:
        return ""

    lines: list[str] = ["Contexto de vida actual:"]

    if patterns_list:
        lines.append("- Patrones activos:")
        for p in patterns_list:
            lines.append(f"  · {_pattern_line(p)}")

    if edges_list:
        lines.append("- Conexiones recientes en el grafo:")
        for e in edges_list[:5]:   # cap at 5 to keep prompt manageable
            lines.append(f"  · {_edge_line(e)}")

    return "\n".join(lines)


def build_bundle(
    *,
    db=None,            # unused; kept for forward-compatibility (e.g. passing a test DB)
    now: datetime | None = None,
    domain_hint: str | None = None,
) -> CorrelationBundle:
    """Gather active patterns + relevant graph edges and return a CorrelationBundle.

    Parameters
    ----------
    db:
        Reserved for test injection. Currently ignored — each DAO uses its own
        module-level connection. Kept in signature so tests can pass it without
        breaking the contract as the codebase evolves.
    now:
        Anchor point for time-relative queries. Defaults to utcnow().
    domain_hint:
        Optional domain tag (e.g. ``"finance"``, ``"health"``) to filter edges.
        When provided, only edges whose src_domain or dst_domain matches are
        included.
    """
    _now = now or datetime.now(timezone.utc)

    # ── 1. Active patterns ──────────────────────────────────────────────────
    from lifeos.insights.patterns import detect_all  # noqa: PLC0415

    try:
        patterns = detect_all(cadence="weekly")
    except Exception:  # noqa: BLE001
        log.warning("detect_all failed — using empty pattern list", exc_info=True)
        patterns = []

    # ── 2. Relevant edges ───────────────────────────────────────────────────
    from lifeos import edges  # noqa: PLC0415

    relevant_edges: list = []
    try:
        # Fetch recent pattern-active-at edges (last 24h) and correlates-with.
        cutoff_iso = (_now - timedelta(hours=24)).isoformat()
        for rel in ("pattern-active-at", "correlates-with"):
            batch = edges.by_relation(rel, limit=50)
            for e in batch:
                # TTL pruning: skip if metadata.expires_at is in the past.
                md = e.metadata or {}
                expires_at = md.get("expires_at")
                if expires_at:
                    try:
                        exp_dt = datetime.fromisoformat(expires_at)
                        if exp_dt.tzinfo is None:
                            exp_dt = exp_dt.replace(tzinfo=timezone.utc)
                        if exp_dt < _now:
                            continue   # expired — skip (lazy TTL enforcement)
                    except (ValueError, TypeError):
                        pass

                if domain_hint:
                    if domain_hint not in (e.src_domain, e.dst_domain):
                        continue
                relevant_edges.append(e)
    except Exception:  # noqa: BLE001
        log.warning("edges query failed — using empty edge list", exc_info=True)

    summary = render_summary(patterns, relevant_edges)
    return CorrelationBundle(
        active_patterns=patterns,
        relevant_edges=relevant_edges,
        edge_summary=summary,
    )


# ─── APScheduler job ──────────────────────────────────────────────────────────


def _run_correlation_snapshot() -> None:
    """Hourly job: persist active patterns as edges with a 24h TTL.

    For each active pattern, an edge is created with:
        src = ("insights", "snapshot")
        dst = ("insights", pattern.kind)
        rel = "pattern-active-at"
        metadata.expires_at = now + 24h (ISO)
        metadata.snapshot = True
        metadata.pattern_kind = pattern.kind
        metadata.severity = pattern.severity

    Also prunes expired pattern-active-at edges.
    """
    from lifeos import edges  # noqa: PLC0415
    from lifeos.insights.patterns import detect_all  # noqa: PLC0415

    now = datetime.now(timezone.utc)
    expires_at = (now + timedelta(hours=24)).isoformat()

    # ── Prune expired edges (lazy TTL) ──────────────────────────────────────
    try:
        expired_batch = edges.by_relation("pattern-active-at", limit=500)
        pruned = 0
        for e in expired_batch:
            md = e.metadata or {}
            exp_raw = md.get("expires_at")
            if exp_raw:
                try:
                    exp_dt = datetime.fromisoformat(exp_raw)
                    if exp_dt.tzinfo is None:
                        exp_dt = exp_dt.replace(tzinfo=timezone.utc)
                    if exp_dt < now:
                        edges.delete(e.id)
                        pruned += 1
                except (ValueError, TypeError):
                    pass
        if pruned:
            log.info("pruned %d expired pattern-active-at edges", pruned)
    except Exception:  # noqa: BLE001
        log.warning("TTL pruning failed", exc_info=True)

    # ── Persist active patterns as edges ────────────────────────────────────
    try:
        active = detect_all(cadence="weekly")
    except Exception:  # noqa: BLE001
        log.warning("detect_all failed in snapshot job", exc_info=True)
        return

    for pattern in active:
        try:
            edges.create(
                src=("insights", "snapshot"),
                dst=("insights", pattern.kind),
                rel="pattern-active-at",
                metadata={
                    "expires_at": expires_at,
                    "snapshot": True,
                    "pattern_kind": pattern.kind,
                    "severity": pattern.severity,
                },
                created_by="correlation_snapshot",
            )
        except Exception:  # noqa: BLE001
            log.warning("failed to persist edge for pattern %s", pattern.kind, exc_info=True)

    log.info("correlation_snapshot: %d active patterns persisted", len(active))

    # ── Cross-domain correlation (sleep → impulsive spending) ───────────────
    try:
        corr_result = _detect_sleep_spending_correlation(now)
        if corr_result is not None:
            _persist_correlation_edge(corr_result, now)
    except Exception:  # noqa: BLE001
        log.warning("cross-domain correlation step failed", exc_info=True)


def register(scheduler) -> None:
    """Register the hourly correlation_snapshot job on *scheduler*.

    *scheduler* should be a ``lifeos.scheduler.Scheduler`` instance (or anything
    with a ``._scheduler`` attribute that is an APScheduler
    ``BackgroundScheduler``).

    Call this AFTER ``scheduler.start()`` has been called (same pattern as
    ``insights_cron.start_jobs``).
    """
    from apscheduler.triggers.interval import IntervalTrigger  # noqa: PLC0415

    if not scheduler.running:
        log.warning(
            "lifeos scheduler not running — skipping correlation_snapshot registration"
        )
        return

    scheduler._scheduler.add_job(
        func=_safe_run_snapshot,
        trigger=IntervalTrigger(hours=1),
        id="lifeos.insights.correlation_snapshot",
        replace_existing=True,
        misfire_grace_time=3600,
    )
    log.info("correlation_snapshot job registered (interval=1h)")


def _safe_run_snapshot() -> None:
    try:
        _run_correlation_snapshot()
    except Exception:  # noqa: BLE001
        log.exception("correlation_snapshot job crashed")
