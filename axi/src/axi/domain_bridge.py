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


# ─── backward-compat shim ────────────────────────────────────────────────────


def create_fact_node_for_interaction(interaction: Any) -> int:
    """Backward-compatible shim: create a fact node for a relationships interaction.

    Delegates to create_fact_node_for_entry('relationships', interaction).
    Callers that imported this name from axi.store can migrate to importing
    from axi.domain_bridge instead.
    """
    return create_fact_node_for_entry("relationships", interaction)
