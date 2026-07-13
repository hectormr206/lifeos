"""Domain-coverage gap detection for the autonomous elicitation path.

Read-only. For each of the 7 life domains, decides whether the domain has ANY
entry within the last ``stale_days`` days by calling its module-level
``list_recent(...)`` (each domain opens/closes its own encrypted connection).

A domain with NO recent entry is a "gap". A domain whose store RAISES is
treated as UNKNOWN (never a gap) and logged, so one broken store can never
fabricate an eliciting question.

This module lives OUTSIDE cron.py on purpose: cron.py must stay domain-import
free (see test_no_domain_write_called_on_any_tick_path_real). The resulting
gap list is injected into the tick as ``coverage_fn``.
"""

from __future__ import annotations

import logging
from datetime import datetime

log = logging.getLogger("lifeos.autonomous.coverage")

# Deterministic domain order — this is the order gaps are reported in.
DOMAIN_ORDER: tuple[str, ...] = (
    "health", "finance", "exercise", "relationships",
    "learning", "spirituality", "events",
)


def _has_recent(domain: str, stale_days: int) -> bool:
    """Return True iff ``domain`` has at least one entry in the last
    ``stale_days`` days. Imports are local so the module import graph stays
    lazy and cron.py never transitively pulls in a domain store."""
    n = int(stale_days)
    if domain == "health":
        from lifeos.health import entries
        return bool(entries.list_recent(days=n, limit=1))
    if domain == "finance":
        from lifeos.finance import entries
        return bool(entries.list_recent(days=n, limit=1))
    if domain == "exercise":
        from lifeos.exercise import sessions
        return bool(sessions.list_recent(days=n, limit=1))
    if domain == "relationships":
        from lifeos.relationships import interactions
        return bool(interactions.list_recent(days=n, limit=1))
    if domain == "learning":
        from lifeos.learning import entries
        return bool(entries.list_recent(days=n, limit=1))
    if domain == "spirituality":
        from lifeos.spirituality import entries
        return bool(entries.list_recent(days=n, limit=1))
    if domain == "events":
        # events uses a different window API; count both recent-past AND
        # near-future events as engagement (planning ahead is activity too).
        from lifeos.events import entries
        return bool(entries.list_recent(days_back=n, days_ahead=n, limit=1))
    raise ValueError(f"unknown domain {domain!r}")


def coverage_gaps(*, stale_days: int, now: datetime) -> list[str]:
    """Return the domain keys (in DOMAIN_ORDER) with NO entry in the last
    ``stale_days`` days.

    ``now`` is accepted for API symmetry with the rest of the autonomous
    layer; the domain stores anchor their own SQL ``datetime('now')`` window,
    so it is not used to build the query.

    Best-effort per domain: a domain whose probe raises is treated as UNKNOWN
    (skipped, never a gap) and logged.
    """
    gaps: list[str] = []
    for domain in DOMAIN_ORDER:
        try:
            recent = _has_recent(domain, stale_days)
        except Exception:  # noqa: BLE001
            log.warning(
                "coverage: domain %s probe failed; treating as unknown (not a gap)",
                domain, exc_info=True,
            )
            continue
        if not recent:
            gaps.append(domain)
    return gaps
