"""Registry of specialized-domain chat specs.

The ONE place that lists the available domain chats. Adding a domain is a single
import + a single entry here (plus its spec module) — the engine (axi.domain_chat)
and the endpoint/UI never change. This is the reusable-component invariant.
"""
from __future__ import annotations

from axi.domain_chat import DomainSpec
from axi.health_chat import HEALTH_SPEC

# domain key → spec. Future: FINANCE_SPEC, EXERCISE_SPEC, RELATIONSHIPS_SPEC, …
DOMAINS: dict[str, DomainSpec] = {
    HEALTH_SPEC.key: HEALTH_SPEC,
}


def get_spec(key: str) -> DomainSpec | None:
    """Resolve a domain spec by key (case-insensitive). None if unknown."""
    return DOMAINS.get((key or "").strip().lower())
