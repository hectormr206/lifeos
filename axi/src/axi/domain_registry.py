"""Registry of specialized-domain chat specs.

The ONE place that lists the available domain chats. Adding a domain is a single
import + a single entry here (plus its spec module) — the engine (axi.domain_chat)
and the endpoint/UI never change. This is the reusable-component invariant.
"""
from __future__ import annotations

from axi.calendar_chat import CALENDAR_SPEC
from axi.domain_chat import DomainSpec
from axi.exercise_chat import EXERCISE_SPEC
from axi.finance_chat import FINANCE_SPEC
from axi.health_chat import HEALTH_SPEC
from axi.learning_chat import LEARN_SPEC
from axi.relationships_chat import RELATIONSHIPS_SPEC
from axi.spirituality_chat import SPIRIT_SPEC

DOMAINS: dict[str, DomainSpec] = {
    HEALTH_SPEC.key: HEALTH_SPEC,
    FINANCE_SPEC.key: FINANCE_SPEC,
    SPIRIT_SPEC.key: SPIRIT_SPEC,
    LEARN_SPEC.key: LEARN_SPEC,
    EXERCISE_SPEC.key: EXERCISE_SPEC,
    RELATIONSHIPS_SPEC.key: RELATIONSHIPS_SPEC,
    CALENDAR_SPEC.key: CALENDAR_SPEC,
}


def get_spec(key: str) -> DomainSpec | None:
    """Resolve a domain spec by key (case-insensitive). None if unknown."""
    return DOMAINS.get((key or "").strip().lower())
