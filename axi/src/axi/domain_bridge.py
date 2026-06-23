"""Domain bridge: wire lifeos domain entries into the Axi semantic graph.

For every supported domain (health, relationships, …), this module provides:
- A renderer that converts a domain entry to a short text label suitable for
  embedding (priority: raw_utterance → title → structured fallback).
- bridge_entry(domain, entry): idempotent, best-effort realtime bridging.
  Called immediately after each domain .create() call site.
- create_fact_node_for_entry(domain, entry): core (raises on error).
- create_fact_node_for_interaction(interaction): backward-compat shim →
  create_fact_node_for_entry('relationships', interaction).

Thread safety: all DB writes go through axi.store._tx() (thread-local
connections). trigger_embed_for_node uses a queue — no connection is shared
across threads.
"""
from __future__ import annotations

import logging
import time as _time
from dataclasses import dataclass
from typing import Any, Callable

log = logging.getLogger("axi.domain_bridge")


# ─── DomainConfig ─────────────────────────────────────────────────────────────


@dataclass
class DomainConfig:
    """Per-domain configuration for the bridge.

    Attributes:
        renderer: Pure function (entry) → str used to produce the node label.
        extra_data_fn: Optional pure function (entry) → dict with extra JSON
            data to store on the node. None means use an empty dict.
    """
    renderer: Callable[[Any], str]
    extra_data_fn: Callable[[Any], dict] | None = None


# ─── renderers ───────────────────────────────────────────────────────────────


def _health_renderer(entry: Any) -> str:
    """Render a health entry to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback.
    Whitespace-only strings are treated as absent (stripped before testing).
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    kind = getattr(entry, "kind", "entry")
    return f"health: {kind}"


# ─── domain registry ─────────────────────────────────────────────────────────


def _finance_renderer(entry: Any) -> str:
    """Render a finance entry to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback (kind + amount + currency).
    Whitespace-only strings are treated as absent.
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    kind = getattr(entry, "kind", "expense")
    amount = getattr(entry, "amount", 0)
    currency = getattr(entry, "currency", "MXN")
    return f"finance: {kind} {amount:g} {currency}"[:120]


def _exercise_renderer(entry: Any) -> str:
    """Render an exercise session to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback (kind + duration).
    Whitespace-only strings are treated as absent.
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    kind = getattr(entry, "kind", "other")
    duration = getattr(entry, "duration_minutes", 0)
    return f"exercise: {kind} {duration} min"[:120]


def _spirituality_renderer(entry: Any) -> str:
    """Render a spirituality entry to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback (kind).
    Whitespace-only strings are treated as absent.
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    kind = getattr(entry, "kind", "reflection")
    return f"spirituality: {kind}"[:120]


def _learning_renderer(entry: Any) -> str:
    """Render a learning entry to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback (kind).
    Whitespace-only strings are treated as absent.
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    kind = getattr(entry, "kind", "idea")
    return f"learning: {kind}"[:120]


def _events_renderer(entry: Any) -> str:
    """Render a lifeos-events entry to a short node label (≤120 chars).

    IMPORTANT: Event.raw_utterance is dropped on read (_row_to_event in entries.py
    does not map it), so this renderer NEVER reads raw_utterance — it always uses
    title as the primary source, then appends kind and location when present.

    Format: "{title} ({kind}) en {location}" — kind/location omitted when absent.
    Degenerate fallback (no title): "event: {kind}" to avoid bare "event" label.
    """
    title = getattr(entry, "title", None) or ""
    kind = getattr(entry, "kind", None)
    location = getattr(entry, "location", None)
    if not title.strip():
        return f"event: {kind or 'other'}"[:120]
    label = title.strip()
    if kind:
        label = f"{label} ({kind})"
    if location:
        label = f"{label} en {location}"
    return label[:120]


def _relationships_renderer(entry: Any) -> str:
    """Render a relationships interaction to a short node label (≤120 chars).

    Priority: raw_utterance → title → structured fallback.
    """
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    return f"relationships: {getattr(entry, 'kind', 'interaction')}"


def _relationships_extra_data(entry: Any) -> dict:
    """Extra data fields for relationships nodes (person_id, interaction_id, body)."""
    data: dict = {
        "person_id": getattr(entry, "person_id", None),
        "interaction_id": str(entry.id),
    }
    body = getattr(entry, "body", None)
    if body:
        data["body"] = body
    return data


_DOMAIN_CONFIGS: dict[str, DomainConfig] = {
    "health": DomainConfig(renderer=_health_renderer),
    # Slice 2: fan-out to the 5 remaining structured domains.
    "finance": DomainConfig(renderer=_finance_renderer),
    "exercise": DomainConfig(renderer=_exercise_renderer),
    "spirituality": DomainConfig(renderer=_spirituality_renderer),
    "learning": DomainConfig(renderer=_learning_renderer),
    "lifeos-events": DomainConfig(renderer=_events_renderer),
    # relationships is handled through this bridge as well (Slice 1 shim).
    "relationships": DomainConfig(
        renderer=_relationships_renderer,
        extra_data_fn=_relationships_extra_data,
    ),
}


# ─── core: create_fact_node_for_entry ────────────────────────────────────────


def create_fact_node_for_entry(domain: str, entry: Any) -> int:
    """Create a fact node for a domain entry and register it in domain_node_map.

    Steps:
    1. Check domain_node_map — return existing node_id if already mapped (idempotent).
    2. Render the node label via the domain's renderer.
    3. Call store.add_node('fact', label, domain=domain).
    4. Call store.upsert_domain_node_map(domain, str(entry.id), node_id).
    5. Call store.trigger_embed_for_node(node_id) (async, non-blocking).
    6. Return node_id.

    Raises:
        KeyError: if the domain is not registered in _DOMAIN_CONFIGS.
        Any exception from store operations propagates (use bridge_entry for
        best-effort / swallowed errors).
    """
    from axi import store

    entry_id = str(entry.id)

    # Idempotency guard: return existing node if already bridged.
    existing = store.get_node_for_domain_entry(domain, entry_id)
    if existing is not None:
        return existing

    cfg = _DOMAIN_CONFIGS[domain]
    label = cfg.renderer(entry)

    extra: dict[str, Any] = {}
    if cfg.extra_data_fn is not None:
        extra = cfg.extra_data_fn(entry)

    node_id = store.add_node("fact", label, data=extra or None, domain=domain)
    store.upsert_domain_node_map(domain, entry_id, node_id)
    store.trigger_embed_for_node(node_id)
    return node_id


# ─── best-effort wrapper: bridge_entry ───────────────────────────────────────


def bridge_entry(domain: str, entry: Any) -> int | None:
    """Best-effort wrapper around create_fact_node_for_entry.

    Never raises. Returns the node_id on success, or None if any error occurs.
    A warning is logged on failure so problems are visible without breaking
    the caller's write path.
    """
    try:
        return create_fact_node_for_entry(domain, entry)
    except Exception as exc:  # noqa: BLE001
        log.warning(
            "bridge_entry: failed to bridge domain=%r entry=%r: %s",
            domain, getattr(entry, "id", "<no id>"), exc,
        )
        return None


# ─── historical backfill ─────────────────────────────────────────────────────


def _fetch_domain_entries(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
    """Fetch recent entries for a given domain from its lifeos store.

    This is the injectable seam used by backfill_all_domains.  Tests patch
    this function to inject fake entries without touching the real lifeos stores.

    Returns an empty list if the domain store is unavailable or not migrated.

    Args:
        domain:  Domain key (must match _DOMAIN_CONFIGS keys).
        days:    Look-back window in days (passed as `days` or `days_back`).
        limit:   Optional upper bound on entries fetched (defaults to store default).
    """
    try:
        if domain == "health":
            from lifeos.health import entries as _he
            kwargs: dict[str, Any] = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _he.list_recent(**kwargs)

        if domain == "finance":
            from lifeos.finance import entries as _fe
            kwargs = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _fe.list_recent(**kwargs)

        if domain == "exercise":
            from lifeos.exercise import sessions as _ex
            kwargs = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _ex.list_recent(**kwargs)

        if domain == "spirituality":
            from lifeos.spirituality import entries as _se
            kwargs = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _se.list_recent(**kwargs)

        if domain == "learning":
            from lifeos.learning import entries as _le
            kwargs = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _le.list_recent(**kwargs)

        if domain == "lifeos-events":
            from lifeos.events import entries as _ev
            # Events uses `days_back` instead of `days`.
            kwargs = {"days_back": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _ev.list_recent(**kwargs)

        if domain == "relationships":
            from lifeos.relationships import interactions as _rel
            kwargs = {"days": days}
            if limit is not None:
                kwargs["limit"] = limit
            return _rel.list_recent(**kwargs)

    except Exception as exc:  # noqa: BLE001
        log.warning(
            "_fetch_domain_entries: failed to fetch domain=%r: %s", domain, exc
        )
    return []


def backfill_all_domains(
    *,
    days: int = 90,
    batch_size: int = 50,
    sleep_s: float = 0.1,
    node_limit: int | None = None,
) -> dict[str, int]:
    """Bounded, rate-limited, idempotent historical backfill across all domains.

    For every domain registered in _DOMAIN_CONFIGS, fetches existing entries
    within the last *days* days and calls create_fact_node_for_entry for any
    entry NOT already recorded in domain_node_map.

    Args:
        days:        Look-back window in days for each domain's fetch.
        batch_size:  Rate-limiting granularity — sleep after this many newly
                     bridged nodes (across ALL domains combined).
        sleep_s:     Seconds to sleep between batches (respects embed queue cap).
        node_limit:  If set, stop creating new nodes once this many NEW nodes
                     have been created across all domains combined.

    Returns:
        Dict mapping domain → number of NEW nodes created in this run.
        Already-bridged entries do not count.

    Idempotency:
        Running twice with the same parameters is a no-op for already-bridged
        entries — create_fact_node_for_entry's guard skips them.

    Thread safety:
        All writes go through store._tx() (thread-local connections).  The
        caller must not share the returned node ids across threads.
    """
    result: dict[str, int] = {domain: 0 for domain in _DOMAIN_CONFIGS}
    total_created = 0

    for domain in _DOMAIN_CONFIGS:
        if node_limit is not None and total_created >= node_limit:
            break

        entries = _fetch_domain_entries(domain, days=days)

        for entry in entries:
            if node_limit is not None and total_created >= node_limit:
                break

            try:
                from axi import store
                # Idempotency check: skip entries already in domain_node_map.
                existing = store.get_node_for_domain_entry(domain, str(entry.id))
                if existing is not None:
                    continue

                create_fact_node_for_entry(domain, entry)
                result[domain] += 1
                total_created += 1

            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "backfill_all_domains: failed for domain=%r entry=%r: %s",
                    domain, getattr(entry, "id", "<no id>"), exc,
                )
                continue

            # Rate-limiting: pause after each batch.
            if sleep_s > 0 and total_created % batch_size == 0:
                _time.sleep(sleep_s)

    return result


# ─── backward-compat shim ────────────────────────────────────────────────────


def create_fact_node_for_interaction(interaction: Any) -> int:
    """Backward-compatible shim: create a fact node for a relationships interaction.

    Delegates to create_fact_node_for_entry('relationships', interaction).
    Callers that imported this name from axi.store can migrate to importing
    from axi.domain_bridge instead.
    """
    return create_fact_node_for_entry("relationships", interaction)
