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

import functools
import logging
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from datetime import date
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


def filter_unexpired(edges_list: list, now: datetime) -> list:
    """Return only the edges that have not yet expired.

    Rules (behavior-preserving extract from build_bundle):
    - Edge with no metadata.expires_at → kept.
    - Edge with expires_at parseable as ISO datetime:
        - Naive datetime → treated as UTC.
        - If exp_dt < now → dropped (expired).
        - Otherwise → kept.
    - Edge with non-parseable expires_at (ValueError / TypeError) → kept (silent pass).
    """
    kept = []
    for e in edges_list:
        md = e.metadata or {}
        expires_at = md.get("expires_at")
        if expires_at:
            try:
                exp_dt = datetime.fromisoformat(expires_at)
                if exp_dt.tzinfo is None:
                    exp_dt = exp_dt.replace(tzinfo=timezone.utc)
                if exp_dt < now:
                    continue  # expired — skip
            except (ValueError, TypeError):
                pass
        kept.append(e)
    return kept


@dataclass(frozen=True)
class LaggedCorrelationResult:
    """Generic metrics from the pure lagged-correlation primitive."""

    trigger_count: int           # number of trigger days (|trigger_days|)
    non_trigger_count: int       # number of non-trigger days
    events_after_trigger: int    # trigger days with >=1 event in lag window
    events_after_non_trigger: int  # non-trigger days with >=1 event in lag window
    total_events: int            # |event_days| (all event days in window)
    rate_ratio: float
    window_days: int
    lag_days: int
    evidence: "dict | None" = None  # optional explainability dict, MUST be last


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
    evidence: "dict | None" = None  # optional explainability dict, MUST be last


# ─── Pure lagged-correlation primitive ───────────────────────────────────────


def _detect_lagged_correlation(
    *,
    trigger_days: "set[date]",
    non_trigger_days: "set[date]",
    event_days: "set[date]",
    n_trigger_days: int,
    n_non_trigger_days: int,
    window_days: int,
    lag_days: int,
    min_trigger_days: int,
    min_total_events: int,
    min_rate_ratio: float,
    rate_floor: float = 0.001,
) -> "LaggedCorrelationResult | None":
    """Pure function: detect whether trigger days correlate with events within lag window.

    Guard order (must match existing behavior):
      1. trigger count guard
      2. total events guard
      3. rate_ratio guard

    Lag match: a trigger day d is matched if any event_day falls in
    {d + timedelta(days=lag) for lag in range(lag_days + 1)}, i.e. lag in [0..lag_days].
    Days BEFORE the trigger are never counted (negative lag not in range).
    """
    # Guard A: trigger count
    if n_trigger_days < min_trigger_days:
        return None

    # Guard B: total events (cheap pre-filter)
    total_events = len(event_days)
    if total_events < min_total_events:
        return None

    # Lag match counts
    events_after_trigger = sum(
        1 for d in trigger_days
        if any((d + timedelta(days=lag)) in event_days for lag in range(lag_days + 1))
    )
    events_after_non_trigger = sum(
        1 for d in non_trigger_days
        if any((d + timedelta(days=lag)) in event_days for lag in range(lag_days + 1))
    )

    rate_trigger = events_after_trigger / n_trigger_days
    rate_non = (
        events_after_non_trigger / n_non_trigger_days
        if n_non_trigger_days > 0 else 0.0
    )
    rate_ratio = rate_trigger / max(rate_non, rate_floor)

    # Guard C: rate ratio
    if rate_ratio < min_rate_ratio:
        return None

    return LaggedCorrelationResult(
        trigger_count=n_trigger_days,
        non_trigger_count=n_non_trigger_days,
        events_after_trigger=events_after_trigger,
        events_after_non_trigger=events_after_non_trigger,
        total_events=total_events,
        rate_ratio=rate_ratio,
        window_days=window_days,
        lag_days=lag_days,
    )


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
    """Adapter: build trigger/event sets, call primitive, map result to CorrelationResult.

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
    if not sleep_by_day:
        return None

    # Build trigger/non-trigger sets from sleep classification
    trigger_days = {d for d, h in sleep_by_day.items() if h < _SLEEP_THRESHOLD}
    non_trigger_days = set(sleep_by_day) - trigger_days
    event_days = _impulsive_purchase_days(finance_raw)

    lagged = _detect_lagged_correlation(
        trigger_days=trigger_days,
        non_trigger_days=non_trigger_days,
        event_days=event_days,
        n_trigger_days=len(trigger_days),
        n_non_trigger_days=len(non_trigger_days),
        window_days=_WINDOW_DAYS,
        lag_days=_LAG_DAYS,
        min_trigger_days=_MIN_POOR_SLEEP_DAYS,
        min_total_events=_MIN_TOTAL_IMPULSIVE,
        min_rate_ratio=_MIN_RATE_RATIO,
        rate_floor=_OK_RATE_FLOOR,
    )

    if lagged is None:
        return None

    # Map LaggedCorrelationResult → CorrelationResult (byte-identical public contract)
    result = CorrelationResult(
        rate_ratio=lagged.rate_ratio,
        poor_sleep_days=lagged.trigger_count,
        ok_sleep_days=lagged.non_trigger_count,
        impulsive_after_poor=lagged.events_after_trigger,
        impulsive_after_ok=lagged.events_after_non_trigger,
        total_impulsive=lagged.total_events,
        window_days=lagged.window_days,
        lag_days=lagged.lag_days,
        threshold=_SLEEP_THRESHOLD,
    )

    # Collect evidence from raw impulsive purchase entries
    impulsive_entries = [e for e in finance_raw if "impulsive" in (e.tags or [])]
    evidence = _collect_evidence(
        trigger_days,
        impulsive_entries,
        _LAG_DAYS,
        label_fn=lambda e: f"{e.title} ${e.amount:.0f}",
        event_label="Compras impulsivas",
    )
    return replace(result, evidence=evidence)


# ─── New helpers ─────────────────────────────────────────────────────────────


def _conflict_days(interactions) -> "set[date]":
    """Return the set of UTC dates that have at least one conflict interaction."""
    from datetime import date as _date  # noqa: PLC0415
    days: set = set()
    for i in interactions:
        if i.kind == "conflict":
            days.add(i.ts.astimezone(timezone.utc).date())
    return days


def _exercise_days(sessions) -> "set[date]":
    """Return the set of UTC dates that have at least one exercise session."""
    days: set = set()
    for s in sessions:
        days.add(s.ts.astimezone(timezone.utc).date())
    return days


def _window_dates(now: datetime, window_days: int) -> "set[date]":
    """Return the set of UTC dates in the calendar window [today-window_days+1, today]."""
    today = now.astimezone(timezone.utc).date()
    return {today - timedelta(days=i) for i in range(window_days)}


# ─── Evidence helper ──────────────────────────────────────────────────────────


def _collect_evidence(
    trigger_days: "set[date]",
    event_entries: list,
    lag_days: int,
    *,
    label_fn: "Callable",
    event_label: str,
    max_items: int = 8,
) -> dict:
    """Pure helper: collect matching event entries and return an evidence dict.

    For each entry, its UTC date must fall within [t .. t+lag_days] for at
    least one trigger day t (i.e. 0 <= (day - t).days <= lag_days).
    Entries are sorted date-descending (most recent first) and capped at
    max_items.  matched_pairs is the true count BEFORE capping.

    Returns a dict with keys:
        event_label  – domain label (Spanish string supplied by caller)
        event_items  – list of {date: "YYYY-MM-DD", label: str}, <= max_items
        matched_pairs – int, true total before cap
        capped        – bool, True iff matched_pairs > max_items
    """
    matched: list = []
    for e in event_entries:
        day = e.ts.astimezone(timezone.utc).date()
        if any(0 <= (day - t).days <= lag_days for t in trigger_days):
            matched.append((e, day))

    matched_pairs = len(matched)
    matched.sort(key=lambda pair: pair[1], reverse=True)  # date desc
    capped = matched_pairs > max_items
    event_items = [
        {"date": day.isoformat(), "label": label_fn(e)}
        for e, day in matched[:max_items]
    ]
    return {
        "event_label": event_label,
        "event_items": event_items,
        "matched_pairs": matched_pairs,
        "capped": capped,
    }


# ─── Generic persist ──────────────────────────────────────────────────────────


def _persist_correlation_edge_for(
    result: "LaggedCorrelationResult",
    now: datetime,
    *,
    src: "tuple[str, str]",
    dst: "tuple[str, str]",
    note_fn: "Callable[[LaggedCorrelationResult], str]",
    edges_mod=None,
) -> "Edge":
    """Generic dedup-then-write for any detector edge.

    Deduplicates on src[1] / dst[1] within 'correlates-with' edges for the
    given src_domain / dst_domain pair. Metadata uses generic keys.
    """
    if edges_mod is None:
        from lifeos import edges as _edges  # noqa: PLC0415
        edges_mod = _edges

    # Dedup: remove any prior edge with the same logical identity
    for e in edges_mod.by_relation(
        "correlates-with",
        src_domain=src[0],
        dst_domain=dst[0],
        limit=200,
    ):
        if e.src_id == src[1] and e.dst_id == dst[1]:
            edges_mod.delete(e.id)

    expires_at = (now + timedelta(days=_TTL_DAYS)).isoformat()
    note = note_fn(result)

    metadata: dict = {
        "strength": round(result.rate_ratio, 2),
        "rate_ratio": round(result.rate_ratio, 2),
        "window_days": result.window_days,
        "lag_days": result.lag_days,
        "trigger_count": result.trigger_count,
        "events_after_trigger": result.events_after_trigger,
        "total_events": result.total_events,
        "expires_at": expires_at,
        "snapshot": True,
        "note": note,
    }
    if result.evidence is not None:
        metadata["evidence"] = result.evidence

    return edges_mod.create(
        src=src,
        dst=dst,
        rel="correlates-with",
        metadata=metadata,
        created_by="correlation_snapshot",
    )


# ─── Persist step (sleep bespoke wrapper) ─────────────────────────────────────


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

    metadata: dict = {
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
    }
    if result.evidence is not None:
        metadata["evidence"] = result.evidence

    return edges_mod.create(
        src=("health", "sleep_deficit_pattern"),
        dst=("finance", "impulsive_spending"),
        rel="correlates-with",
        metadata=metadata,
        created_by="correlation_snapshot",
    )


# ─── Note functions for new detectors ────────────────────────────────────────


def _sleep_conflicts_note(result: "LaggedCorrelationResult") -> str:
    return (
        f"Conflictos {result.rate_ratio:.1f}× más frecuentes tras noches de mal sueño "
        f"(<6.5h), basado en {result.trigger_count} días de sueño deficiente."
    )


def _exercise_gap_note(result: "LaggedCorrelationResult") -> str:
    return (
        f"Compras impulsivas {result.rate_ratio:.1f}× más frecuentes en días sin ejercicio, "
        f"basado en {result.trigger_count} días sin actividad física."
    )


def _conflict_spending_note(result: "LaggedCorrelationResult") -> str:
    return (
        f"Compras impulsivas {result.rate_ratio:.1f}× más frecuentes tras días de conflicto, "
        f"basado en {result.trigger_count} días de conflicto."
    )


# ─── New detectors ────────────────────────────────────────────────────────────


def _detect_sleep_conflicts_correlation(
    now: datetime,
    *,
    health_list_recent=None,
    rel_list_recent=None,
) -> "LaggedCorrelationResult | None":
    """Detect whether poor-sleep days correlate with relationship conflict days.

    Returns a LaggedCorrelationResult when all guards pass, otherwise None.
    Inject `health_list_recent` / `rel_list_recent` callables for unit testing.
    """
    if health_list_recent is None:
        from lifeos.health import entries as health_entries  # noqa: PLC0415
        health_list_recent = health_entries.list_recent

    if rel_list_recent is None:
        from lifeos.relationships import interactions as rel_interactions  # noqa: PLC0415
        rel_list_recent = rel_interactions.list_recent

    sleep_raw = health_list_recent(days=_WINDOW_DAYS, kind="vital")
    rel_raw = rel_list_recent(days=_WINDOW_DAYS)

    sleep_by_day = _bucket_sleep_by_day(sleep_raw)
    if not sleep_by_day:
        return None

    trigger_days = {d for d, h in sleep_by_day.items() if h < _SLEEP_THRESHOLD}
    non_trigger_days = set(sleep_by_day) - trigger_days
    conflict_interactions = [i for i in rel_raw if i.kind == "conflict"]
    event_days = {i.ts.astimezone(timezone.utc).date() for i in conflict_interactions}

    if not event_days:
        return None

    result = _detect_lagged_correlation(
        trigger_days=trigger_days,
        non_trigger_days=non_trigger_days,
        event_days=event_days,
        n_trigger_days=len(trigger_days),
        n_non_trigger_days=len(non_trigger_days),
        window_days=_WINDOW_DAYS,
        lag_days=_LAG_DAYS,
        min_trigger_days=_MIN_POOR_SLEEP_DAYS,
        min_total_events=_MIN_TOTAL_IMPULSIVE,
        min_rate_ratio=_MIN_RATE_RATIO,
        rate_floor=_OK_RATE_FLOOR,
    )

    if result is None:
        return None

    evidence = _collect_evidence(
        trigger_days,
        conflict_interactions,
        _LAG_DAYS,
        label_fn=lambda i: i.title,
        event_label="Conflictos",
    )
    return replace(result, evidence=evidence)


def _detect_exercise_gap_spending_correlation(
    now: datetime,
    *,
    exercise_list_recent=None,
    finance_list_recent=None,
) -> "LaggedCorrelationResult | None":
    """Detect whether non-exercise days (gaps) correlate with impulsive spending.

    Guard: user must have >=5 actual exercise days in the window to avoid
    trivial fire for inactive/new users.

    Returns a LaggedCorrelationResult when all guards pass, otherwise None.
    """
    if exercise_list_recent is None:
        from lifeos.exercise import sessions as ex_sessions  # noqa: PLC0415
        exercise_list_recent = ex_sessions.list_recent

    if finance_list_recent is None:
        from lifeos.finance import entries as finance_entries  # noqa: PLC0415
        finance_list_recent = finance_entries.list_recent

    ex_raw = exercise_list_recent(days=_WINDOW_DAYS)
    finance_raw = finance_list_recent(days=_WINDOW_DAYS, kind="big_purchase")

    actual_exercise_days = _exercise_days(ex_raw)

    # Guard: require >=5 exercise days to avoid trivial fires for inactive users
    if len(actual_exercise_days) < 5:
        return None

    window = _window_dates(now, _WINDOW_DAYS)
    trigger_days = window - actual_exercise_days   # gap days (no exercise)
    non_trigger_days = actual_exercise_days & window  # exercise days in window
    impulsive_entries = [e for e in finance_raw if "impulsive" in (e.tags or [])]
    event_days = {e.ts.astimezone(timezone.utc).date() for e in impulsive_entries}

    result = _detect_lagged_correlation(
        trigger_days=trigger_days,
        non_trigger_days=non_trigger_days,
        event_days=event_days,
        n_trigger_days=len(trigger_days),
        n_non_trigger_days=len(non_trigger_days),
        window_days=_WINDOW_DAYS,
        lag_days=_LAG_DAYS,
        min_trigger_days=5,
        min_total_events=2,
        min_rate_ratio=_MIN_RATE_RATIO,
        rate_floor=_OK_RATE_FLOOR,
    )

    if result is None:
        return None

    evidence = _collect_evidence(
        trigger_days,
        impulsive_entries,
        _LAG_DAYS,
        label_fn=lambda e: f"{e.title} ${e.amount:.0f}",
        event_label="Compras impulsivas",
    )
    return replace(result, evidence=evidence)


def _detect_conflict_spending_correlation(
    now: datetime,
    *,
    rel_list_recent=None,
    finance_list_recent=None,
) -> "LaggedCorrelationResult | None":
    """Detect whether conflict days correlate with impulsive spending (retail-therapy pattern).

    Returns a LaggedCorrelationResult when all guards pass, otherwise None.
    Inject `rel_list_recent` / `finance_list_recent` callables for unit testing.
    """
    if rel_list_recent is None:
        from lifeos.relationships import interactions as rel_interactions  # noqa: PLC0415
        rel_list_recent = rel_interactions.list_recent

    if finance_list_recent is None:
        from lifeos.finance import entries as finance_entries  # noqa: PLC0415
        finance_list_recent = finance_entries.list_recent

    rel_raw = rel_list_recent(days=_WINDOW_DAYS, kind="conflict")
    finance_raw = finance_list_recent(days=_WINDOW_DAYS, kind="big_purchase")

    conflict_days = _conflict_days(rel_raw)
    impulsive_entries = [e for e in finance_raw if "impulsive" in (e.tags or [])]
    event_days = {e.ts.astimezone(timezone.utc).date() for e in impulsive_entries}

    trigger_days = conflict_days
    non_trigger_days = _window_dates(now, _WINDOW_DAYS) - conflict_days

    result = _detect_lagged_correlation(
        trigger_days=trigger_days,
        non_trigger_days=non_trigger_days,
        event_days=event_days,
        n_trigger_days=len(trigger_days),
        n_non_trigger_days=len(non_trigger_days),
        window_days=_WINDOW_DAYS,
        lag_days=_LAG_DAYS,
        min_trigger_days=_MIN_POOR_SLEEP_DAYS,
        min_total_events=_MIN_TOTAL_IMPULSIVE,
        min_rate_ratio=_MIN_RATE_RATIO,
        rate_floor=_OK_RATE_FLOOR,
    )

    if result is None:
        return None

    evidence = _collect_evidence(
        trigger_days,
        impulsive_entries,
        _LAG_DAYS,
        label_fn=lambda e: f"{e.title} ${e.amount:.0f}",
        event_label="Compras impulsivas",
    )
    return replace(result, evidence=evidence)


# ─── Detector registry ───────────────────────────────────────────────────────

_DETECTORS: list[tuple] = [
    # (detect_fn, cfg)
    # Sleep → impulsive spending (bespoke legacy persist)
    (
        _detect_sleep_spending_correlation,
        {
            "name": "sleep_spending",
            "persist": _persist_correlation_edge,
        },
    ),
    # Sleep → relationship conflicts (generic persist)
    (
        _detect_sleep_conflicts_correlation,
        {
            "name": "sleep_conflicts",
            "persist": functools.partial(
                _persist_correlation_edge_for,
                src=("health", "sleep_deficit_pattern"),
                dst=("relationships", "conflict_pattern"),
                note_fn=_sleep_conflicts_note,
            ),
        },
    ),
    # Exercise gap → impulsive spending (generic persist)
    (
        _detect_exercise_gap_spending_correlation,
        {
            "name": "exercise_gap_spending",
            "persist": functools.partial(
                _persist_correlation_edge_for,
                src=("exercise", "inactivity_pattern"),
                dst=("finance", "impulsive_spending"),
                note_fn=_exercise_gap_note,
            ),
        },
    ),
    # Conflict days → impulsive spending (retail-therapy pattern)
    (
        _detect_conflict_spending_correlation,
        {
            "name": "conflict_spending",
            "persist": functools.partial(
                _persist_correlation_edge_for,
                src=("relationships", "conflict_pattern"),
                dst=("finance", "impulsive_spending"),
                note_fn=_conflict_spending_note,
            ),
        },
    ),
]


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
            for e in filter_unexpired(batch, _now):
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

    # ── Cross-domain correlations (all detectors via _DETECTORS loop) ────────
    for detect_fn, cfg in _DETECTORS:
        try:
            result = detect_fn(now)
            if result is not None:
                cfg["persist"](result, now)
        except Exception:  # noqa: BLE001
            log.warning(
                "correlation detector '%s' failed", cfg.get("name", "?"), exc_info=True
            )


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
