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
