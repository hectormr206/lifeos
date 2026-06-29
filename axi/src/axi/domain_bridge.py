"""Domain bridge: wire lifeos domain entries into the Axi semantic graph.

For every supported domain (health, relationships, …), this module provides:
- A renderer that converts a domain entry to a short text label suitable for
  embedding (priority: raw_utterance → title → structured fallback).
- bridge_entry(domain, entry): idempotent, best-effort realtime bridging.
  Called immediately after each domain .create() call site.
- create_fact_node_for_entry(domain, entry): core (raises on error).
- create_fact_node_for_interaction(interaction): backward-compat shim →
  create_fact_node_for_entry('relationships', interaction).
- backfill_node_occurred_at(): one-time helper to fill occurred_at on
  previously backfilled nodes that were inserted before the occurred_at
  column existed. Idempotent and bounded.

Thread safety: all DB writes go through axi.store._tx() (thread-local
connections). trigger_embed_for_node uses a queue — no connection is shared
across threads.
"""
from __future__ import annotations

import logging
import time as _time
from dataclasses import dataclass
from datetime import datetime, timezone
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

    TITLE-FIRST (unlike the other domains): for health the title is the
    NORMALIZED structured summary ("presión 110/81, pulso 51"), which is both
    semantically findable (carries keywords like "presión") AND interpretable by
    the brain — strictly better than the raw utterance ("110 81 51 pulsos"),
    which is keyword-poor and was being mis-read (or fabricated around) when it
    became the recall label. Falls back to raw_utterance, then a structured
    fallback. Whitespace-only strings are treated as absent.
    """
    title = getattr(entry, "title", None)
    if title and title.strip():
        return title.strip()[:120]
    raw = getattr(entry, "raw_utterance", None)
    if raw and raw.strip():
        return raw.strip()[:120]
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


# ─── low-value filter ────────────────────────────────────────────────────────


def _is_low_value(label: str, entry: Any) -> bool:
    """Return True when *label* is clearly contentless and must not become a graph node.

    Conservative filter — only drop true garbage; keep anything with signal.

    Rules (evaluated in order; first match wins):
    1. Strip the label. If empty → True (low value).
    2. If the stripped label contains ANY digit → False (keep).
       Vitals/finance/sleep all carry numbers: "dormí 10.7h", "presión 120/86",
       "gasté 450 en super".
    3. If ALL three conditions hold → True (low value — bare keyword):
       a. The stripped label is a SINGLE token (no whitespace).
       b. The single token is short (≤ 14 chars).
       c. The entry carries NO real content:
          - ``raw_utterance`` is falsy/empty/whitespace-only, AND
          - ``data`` is empty/missing, AND
          - no meaningful numeric field (``amount``, ``duration_minutes``,
            ``duration``) is set — finance/exercise entries with a real value
            must always be kept even when they lack a raw_utterance.
    4. Otherwise → False (keep).  Multi-word labels, long single tokens, or
       entries with non-empty raw_utterance, data, or numeric fields are
       preserved.
    """
    stripped = label.strip()
    if not stripped:
        return True

    if any(ch.isdigit() for ch in stripped):
        return False

    # Single-token short bare-keyword check.
    if len(stripped.split()) == 1 and len(stripped) <= 14:
        raw = getattr(entry, "raw_utterance", None)
        has_raw = bool(raw and raw.strip())
        data = getattr(entry, "data", None)
        has_data = bool(data)
        body = getattr(entry, "body", None)
        has_body = bool(body and body.strip())
        # Also treat any entry with a meaningful numeric field (amount, duration,
        # duration_minutes, etc.) as having real content — finance/exercise entries
        # often carry no raw_utterance but do have structured numeric values.
        # Use `is not None` (not truthiness) so zero values (e.g. amount=0 for a
        # free transaction, duration_minutes=0) are treated as present numeric data.
        has_numeric = (
            getattr(entry, "amount", None) is not None
            or getattr(entry, "duration_minutes", None) is not None
            or getattr(entry, "duration", None) is not None
        )
        if not has_raw and not has_data and not has_body and not has_numeric:
            return True

    return False


# ─── event-date extraction ───────────────────────────────────────────────────


def _entry_occurred_at(entry: Any) -> float | None:
    """Extract the real event timestamp from a domain entry.

    Priority: entry.ts → entry.created_at → None.
    Accepts datetime objects, ISO-format strings, or numeric epoch values.
    Returns a float Unix epoch (UTC seconds) or None when no timestamp is
    available or the value cannot be parsed.
    """
    for attr in ("ts", "created_at"):
        raw = getattr(entry, attr, None)
        if raw is None:
            continue
        # Already a number (epoch seconds).
        if isinstance(raw, (int, float)):
            return float(raw)
        # datetime object.
        if isinstance(raw, datetime):
            # Attach UTC when naive (treat as UTC, consistent with the rest of the stack).
            if raw.tzinfo is None:
                raw = raw.replace(tzinfo=timezone.utc)
            return raw.timestamp()
        # ISO string (e.g. "2026-06-24 12:19:52+00:00").
        if isinstance(raw, str):
            raw_s = raw.strip()
            if not raw_s:
                continue
            try:
                dt = datetime.fromisoformat(raw_s)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.timestamp()
            except (ValueError, TypeError):
                log.debug(
                    "_entry_occurred_at: could not parse timestamp string %r — skipping",
                    raw_s,
                )
                continue
    return None


# ─── core: create_fact_node_for_entry ────────────────────────────────────────


def create_fact_node_for_entry(domain: str, entry: Any) -> int | None:
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

    if _is_low_value(label, entry):
        log.debug(
            "bridge: skipping low-value entry label=%r domain=%r",
            label, domain,
        )
        return None

    extra: dict[str, Any] = {}
    if cfg.extra_data_fn is not None:
        extra = cfg.extra_data_fn(entry)

    occurred_at = _entry_occurred_at(entry)
    node_id = store.add_node("fact", label, data=extra or None, domain=domain, occurred_at=occurred_at)
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

# Generous per-domain fetch cap for backfill runs.  The round-robin node_limit
# in backfill_all_domains still bounds how many nodes are CREATED per run;
# this constant only widens the fetch pool so older entries are candidates.
_BACKFILL_FETCH_LIMIT = 10_000


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

        else:
            log.warning(
                "_fetch_domain_entries: unrecognised domain=%r — no fetch handler registered",
                domain,
            )
            return []

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
    domains: list[str] | None = None,
) -> dict[str, int]:
    """Bounded, rate-limited, idempotent historical backfill across all domains.

    For every domain registered in _DOMAIN_CONFIGS (or the subset given by
    *domains*), fetches existing entries within the last *days* days and calls
    create_fact_node_for_entry for any entry NOT already recorded in
    domain_node_map.

    Fairness: entries are processed in round-robin order across domains so that
    no single domain can consume the entire node_limit budget, preventing
    perpetual starvation of domains listed later in _DOMAIN_CONFIGS.

    Note: sleep_s / batch_size are intentionally generous to give the embed
    worker drain time between batches.

    Args:
        days:        Look-back window in days for each domain's fetch.
        batch_size:  Rate-limiting granularity — sleep after this many newly
                     bridged nodes (across ALL domains combined).
        sleep_s:     Seconds to sleep between batches (respects embed queue cap).
        node_limit:  If set, stop creating new nodes once this many NEW nodes
                     have been created across all domains combined.
        domains:     If set, restrict backfill to these domain keys only
                     (subset of _DOMAIN_CONFIGS). Defaults to all registered
                     domains.

    Returns:
        Dict mapping domain → number of NEW nodes created in this run.
        Already-bridged entries do not count.

    Idempotency:
        Running twice with the same parameters is a no-op for already-bridged
        entries — create_fact_node_for_entry's idempotency guard skips them.

    Thread safety:
        All writes go through store._tx() (thread-local connections).  The
        caller must not share the returned node ids across threads.
    """
    from axi import store

    active_domains: list[str] = (
        [d for d in _DOMAIN_CONFIGS if d in domains]
        if domains is not None
        else list(_DOMAIN_CONFIGS)
    )

    result: dict[str, int] = {domain: 0 for domain in active_domains}
    total_created = 0

    # Fetch all pending (un-bridged) entries per domain upfront so round-robin
    # iteration is deterministic given the same DB state.
    pending: dict[str, list[Any]] = {}
    for domain in active_domains:
        all_entries = _fetch_domain_entries(domain, days=days, limit=_BACKFILL_FETCH_LIMIT)
        # Filter to only un-bridged entries; idempotency is enforced here rather
        # than inside the inner loop so we avoid the TOCTOU double-read.
        domain_pending: list[Any] = []
        for entry in all_entries:
            try:
                existing = store.get_node_for_domain_entry(domain, str(entry.id))
                if existing is None:
                    domain_pending.append(entry)
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "backfill_all_domains: failed idempotency check domain=%r entry=%r: %s",
                    domain, getattr(entry, "id", "<no id>"), exc,
                )
        pending[domain] = domain_pending

    # Round-robin: take one entry per domain per cycle until budget exhausted.
    any_remaining = True
    while any_remaining:
        any_remaining = False
        for domain in active_domains:
            if node_limit is not None and total_created >= node_limit:
                break
            if not pending[domain]:
                continue
            any_remaining = True
            entry = pending[domain].pop(0)
            try:
                node_id = create_fact_node_for_entry(domain, entry)
                if node_id is not None:
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

    # Durability: fold WAL frames into the main DB file before returning so
    # standalone (non-daemon) callers don't silently lose writes on process
    # exit.  A checkpoint while the daemon runs is a normal SQLite operation
    # and does not break concurrent reads.  Failure is logged and swallowed
    # so the caller always receives the result dict.
    try:
        store.checkpoint()
    except Exception as _exc:  # noqa: BLE001
        log.warning("backfill_all_domains: post-backfill checkpoint failed: %s", _exc)

    return result


# ─── one-time occurred_at backfill helper ───────────────────────────────────


def backfill_node_occurred_at(
    *,
    days: int = 36500,
    limit: int | None = None,
) -> int:
    """Idempotent helper: fill occurred_at on nodes that have NULL occurred_at.

    For each node in domain_node_map where occurred_at IS NULL, fetches the
    source domain entry and sets occurred_at from the entry's real timestamp
    (via _entry_occurred_at — same logic as create_fact_node_for_entry).

    This is a one-time migration helper to fix backfilled nodes that were
    inserted before the occurred_at column existed. Safe to run multiple times:
    - Nodes with occurred_at already set are skipped (SELECT before UPDATE).
    - Domains that fail to fetch are skipped with a warning (never raises).

    Args:
        days:  Look-back window passed to _fetch_domain_entries.
               Default is 36500 (≈100 years) so ALL existing entries are
               considered — a one-time migration must not silently skip nodes
               whose real event date is older than the previous 365-day window.
               Pass a smaller value only when testing or when a bounded run is
               explicitly desired.
        limit: Optional cap on total nodes updated in a single run.

    Returns:
        Number of nodes whose occurred_at was updated in this run.
    """
    from axi import store

    conn = store._connect()  # noqa: SLF001

    # Find nodes with occurred_at IS NULL that have a domain_node_map entry.
    # Join gives us the domain and entry_id so we can look up the source entry.
    rows = conn.execute(
        "SELECT n.id AS node_id, d.domain, d.entry_id "
        "FROM nodes n "
        "JOIN domain_node_map d ON d.node_id = n.id "
        "WHERE n.occurred_at IS NULL"
    ).fetchall()

    if not rows:
        return 0

    # Group by domain for efficient batch fetching.
    by_domain: dict[str, dict[str, int]] = {}  # domain → {entry_id: node_id}
    for row in rows:
        domain = row["domain"]
        if domain not in by_domain:
            by_domain[domain] = {}
        by_domain[domain][row["entry_id"]] = int(row["node_id"])

    updated = 0
    for domain, entry_map in by_domain.items():
        if limit is not None and updated >= limit:
            break
        try:
            entries = _fetch_domain_entries(domain, days=days)
        except Exception as exc:  # noqa: BLE001
            log.warning("backfill_node_occurred_at: fetch failed for domain=%r: %s", domain, exc)
            continue

        for entry in entries:
            if limit is not None and updated >= limit:
                break
            entry_id = str(entry.id)
            node_id = entry_map.get(entry_id)
            if node_id is None:
                continue

            epoch = _entry_occurred_at(entry)
            if epoch is None:
                continue

            try:
                cur = conn.execute(
                    "UPDATE nodes SET occurred_at=? WHERE id=? AND occurred_at IS NULL",
                    (epoch, node_id),
                )
                # In autocommit mode (isolation_level=None) the UPDATE commits
                # automatically. Use rowcount so concurrent callers don't both
                # increment when only one wins the SQLite write lock.
                updated += cur.rowcount
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "backfill_node_occurred_at: failed to update node_id=%r: %s", node_id, exc
                )

    return updated


# ─── backward-compat shim ────────────────────────────────────────────────────


def create_fact_node_for_interaction(interaction: Any) -> int:
    """Backward-compatible shim: create a fact node for a relationships interaction.

    Delegates to create_fact_node_for_entry('relationships', interaction).
    Callers that imported this name from axi.store can migrate to importing
    from axi.domain_bridge instead.
    """
    return create_fact_node_for_entry("relationships", interaction)
