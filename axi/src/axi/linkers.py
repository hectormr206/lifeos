"""Cross-domain auto-linkers for the Axi semantic memory graph — Slice 3.

These functions create edges between existing System-A nodes using data already
present in memory.db.  All linkers are IDEMPOTENT (SELECT-before-INSERT) and
bounded to a recent window to avoid full-table scans.

Linkers implemented:
  - run_happened_at_linker   : meeting node → fact node when COALESCE(fact.occurred_at, fact.created_at) ∈ [meeting.start_time ± 1h]
  - run_involves_person_linker: fact node → person node when fact.data.person_id is bridged via domain_node_map
  - run_same_day_linker      : fact node ↔ fact node when both share the same LOCAL calendar day (configured tz)
  - run_mood_at_linker       : mood fact node (data.mood non-null) → event node (meeting, lifeos-events or relationships fact) when within ±1h

Each function:
  - Accepts a live sqlcipher3 connection (same connection the caller uses).
  - Returns an int count of NEW edges created this run.
  - Logs warnings on per-row failures but never propagates exceptions.

run_auto_linkers(conn, *, window_days=90, tz_name="UTC"):
  - Runs all four linkers over a recent bounded window.
  - Returns {happened_at: int, involves_person: int, same_day: int, mood_at: int}.
"""
from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

log = logging.getLogger("axi.linkers")

# ±1 hour tolerance for happened-at matching.
_HAPPENED_AT_WINDOW_S: float = 3600.0

# Look-back window for same-day and happened-at linkers (seconds).
_DEFAULT_WINDOW_DAYS: int = 90

# Per-day fan-out cap for the same-day linker.
# Without this, a day with N=100 fact-nodes produces N*(N-1)/2 = 4950 edges (O(N²)).
# Cap at 50 pairs per day: each node links to at most its K=10 nearest-by-time neighbors.
MAX_SAME_DAY_PAIRS_PER_DAY: int = 50


def _edge_exists(conn, from_id: int, to_id: int, kind: str) -> bool:
    """Return True if an edge of *kind* from *from_id* to *to_id* already exists.

    Resolved through `src_uuid`/`dst_uuid` (PR6 — the reader rewrite), the same
    columns `_safe_insert_edge` writes below. This is the duplicate guard in
    front of every auto-linker insert: read the wrong column and the linker
    stops recognising its own edges and appends a fresh copy on every pass.
    """
    row = conn.execute(
        "SELECT 1 FROM edges WHERE "
        "src_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
        "dst_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
        # PR7: a tombstoned edge must not stop the linker re-creating it.
        "relation = ? AND deleted_at IS NULL LIMIT 1",
        (from_id, to_id, kind),
    ).fetchone()
    return row is not None


def _safe_insert_edge(conn, from_id: int, to_id: int, kind: str) -> bool:
    """Insert edge if not already present. Returns True if a new edge was created.

    The connection is expected to be in autocommit mode (isolation_level=None).
    Do NOT call conn.commit() here — it is a no-op in autocommit and breaks
    when the connection is nested inside an explicit _tx() BEGIN/COMMIT block.
    """
    if _edge_exists(conn, from_id, to_id, kind):
        return False
    # Dual-write src_uuid/dst_uuid alongside from_id/to_id (PR5 "Expand" —
    # design-schema.md Decision 2 step 1), looked up on the same `conn` the
    # insert uses so both stay consistent. from_id/to_id stay authoritative;
    # nothing reads src_uuid/dst_uuid yet.
    now = time.time()
    src_row = conn.execute("SELECT uuid FROM nodes WHERE id = ?", (from_id,)).fetchone()
    dst_row = conn.execute("SELECT uuid FROM nodes WHERE id = ?", (to_id,)).fetchone()
    conn.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at, "
        "src_uuid, dst_uuid, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            from_id, to_id, kind, "{}", now,
            src_row[0] if src_row else None,
            dst_row[0] if dst_row else None,
            now,
        ),
    )
    return True


# ──────────────────────────── happened-at ─────────────────────────────────────


def run_happened_at_linker(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    window_s: float = _HAPPENED_AT_WINDOW_S,
) -> int:
    """Link fact-nodes to meeting nodes when fact event time ∈ [meeting.start_time ± window_s].

    Edge direction: meeting_node → fact_node (kind='happened-at').

    The fact's event time is COALESCE(occurred_at, created_at): the real event
    timestamp when available, falling back to the graph-insertion time when not.
    This fixes the backfill bug where all backfilled nodes share the same
    created_at and would incorrectly link to meetings inserted on the same day.

    Only meetings that have a node_id (linked to a System-A node) are considered.
    Fact-nodes are fetched without a window filter on event time because a
    backfilled fact may have created_at=today but occurred_at=5 days ago (inside
    an older meeting's window). The meeting window cutoff still bounds the search.

    Returns the number of new 'happened-at' edges created.
    """
    cutoff = time.time() - window_days * 86400

    # Fetch meetings with a linked node_id (they have a System-A node).
    meetings = conn.execute(
        "SELECT id, start_time, node_id FROM meetings "
        "WHERE node_id IS NOT NULL AND start_time > ? "
        "ORDER BY start_time DESC",
        (cutoff,),
    ).fetchall()

    if not meetings:
        return 0

    # Fetch fact-nodes whose event time falls within the relevant range.
    # Use COALESCE(occurred_at, created_at) as the canonical event timestamp
    # (same expression used in the inner match loop below).
    #
    # The lower bound is the oldest meeting start_time minus window_s, so no
    # fact that could legitimately match ANY meeting in this run is excluded.
    # This restores bounded complexity (O(meetings × window)) without
    # re-introducing the backfill bug: the cutoff is on the EVENT time
    # (occurred_at when set), not created_at.
    oldest_meeting_start = min(float(m["start_time"]) for m in meetings)
    fact_cutoff = oldest_meeting_start - window_s
    fact_nodes = conn.execute(
        "SELECT id, COALESCE(occurred_at, created_at) AS event_ts FROM nodes "
        "WHERE kind='fact' AND deleted_at IS NULL "
        "AND COALESCE(occurred_at, created_at) > ?",
        (fact_cutoff,),
    ).fetchall()

    if not fact_nodes:
        return 0

    created = 0
    for meeting in meetings:
        meeting_node_id = int(meeting["node_id"])
        start_time = float(meeting["start_time"])
        lo = start_time - window_s
        hi = start_time + window_s

        for fact in fact_nodes:
            fact_id = int(fact["id"])
            fact_ts = float(fact["event_ts"])
            if lo <= fact_ts <= hi:
                try:
                    if _safe_insert_edge(conn, meeting_node_id, fact_id, "happened-at"):
                        created += 1
                except Exception:  # noqa: BLE001
                    log.warning(
                        "happened-at: failed edge (%d → %d)", meeting_node_id, fact_id, exc_info=True
                    )

    return created


# ─────────────────────────── involves-person ──────────────────────────────────


def run_involves_person_linker(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
) -> int:
    """Link fact-nodes to person nodes when fact.data.person_id maps via domain_node_map.

    Strategy:
      1. Load all fact-nodes in the relationships domain (recent window).
      2. Parse each node's data JSON for "person_id".
      3. Look up domain_node_map(domain='relationships_person', entry_id=person_id)
         to find the System-A person node.
      4. Insert an 'involves-person' edge from fact_node → person_node if not already present.

    The domain key 'relationships_person' is used to distinguish person entries
    from interaction entries in the bridge table.

    Returns the number of new 'involves-person' edges created.
    """
    cutoff = time.time() - window_days * 86400

    # Only relationships domain nodes are candidates for person links.
    fact_rows = conn.execute(
        "SELECT id, data FROM nodes "
        "WHERE domain='relationships' AND kind='fact' AND deleted_at IS NULL "
        "AND created_at > ?",
        (cutoff,),
    ).fetchall()

    created = 0
    for row in fact_rows:
        fact_id = int(row["id"])
        try:
            data = json.loads(row["data"]) if row["data"] else {}
        except (json.JSONDecodeError, TypeError):
            continue

        person_id = data.get("person_id")
        if not person_id:
            continue

        # Look up bridge: domain_node_map('relationships_person', person_id).
        bridge_row = conn.execute(
            "SELECT node_id FROM domain_node_map WHERE domain=? AND entry_id=? LIMIT 1",
            ("relationships_person", str(person_id)),
        ).fetchone()
        if bridge_row is None:
            continue

        person_node_id = int(bridge_row["node_id"])
        try:
            if _safe_insert_edge(conn, fact_id, person_node_id, "involves-person"):
                created += 1
        except Exception:  # noqa: BLE001
            log.warning(
                "involves-person: failed edge (%d → %d)", fact_id, person_node_id, exc_info=True
            )

    return created


# ──────────────────────────── same-day ────────────────────────────────────────


def run_same_day_linker(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    tz_name: str = "UTC",
) -> int:
    """Link pairs of fact-nodes that share the same LOCAL calendar day.

    Two facts on the same calendar day (in the user's configured timezone) are
    likely contextually related even without semantic similarity.  Edges are
    created with kind='same-day'.

    Only fact-nodes in the recent *window_days* window are processed.
    Within that window, nodes are grouped by their LOCAL date string (YYYY-MM-DD)
    using COALESCE(occurred_at, created_at) as the event timestamp and *tz_name*
    as the calendar-day reference timezone.

    The look-back window cutoff is epoch-based (tz-agnostic) — only the
    day_key bucketing uses the local tz.

    Using occurred_at (instead of created_at) fixes the backfill "todo ligado"
    bug: entries backfilled on the same day share the same created_at but have
    different real event dates stored in occurred_at.  Only nodes whose real
    event date (or insertion date when occurred_at is NULL) falls within the
    window are considered.

    Args:
        conn: Live sqlcipher3 connection to memory.db.
        window_days: How many days back to look for candidates (default 90).
        tz_name: IANA timezone name used for calendar-day bucketing (e.g.
            'America/Mexico_City').  Defaults to 'UTC'.  If the name is
            invalid, logs a warning and falls back to UTC so the linker
            never crashes due to a misconfigured timezone.

    Returns:
        Number of new 'same-day' edges created.
    """
    # Resolve tz once before the grouping loop.
    try:
        local_tz = ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, KeyError, Exception):
        log.warning(
            "same-day linker: unknown timezone %r — falling back to UTC",
            tz_name,
        )
        local_tz = timezone.utc

    cutoff = time.time() - window_days * 86400

    # Use COALESCE(occurred_at, created_at) as the canonical event timestamp.
    # The window cutoff is also applied to the same expression so nodes are
    # included based on their real event date, not their insertion date.
    rows = conn.execute(
        "SELECT id, COALESCE(occurred_at, created_at) AS event_ts FROM nodes "
        # PR7: the linkers run unattended on every daemon pass. Without this
        # they would quietly rebuild the graph around deleted memories.
        "WHERE kind='fact' AND deleted_at IS NULL "
        "AND COALESCE(occurred_at, created_at) > ? "
        "ORDER BY COALESCE(occurred_at, created_at) ASC",
        (cutoff,),
    ).fetchall()

    # Group by LOCAL date string derived from the real event timestamp.
    by_day: dict[str, list[int]] = {}
    for row in rows:
        ts = float(row["event_ts"])
        day_key = datetime.fromtimestamp(ts, tz=local_tz).strftime("%Y-%m-%d")
        by_day.setdefault(day_key, []).append(int(row["id"]))

    created = 0
    for day_key, node_ids in by_day.items():
        if len(node_ids) < 2:
            continue
        # Cap fan-out per day: link each node to its K nearest-by-event_ts neighbors
        # (node_ids are sorted by COALESCE(occurred_at, created_at) ASC already).
        # This bounds the per-day edge count to MAX_SAME_DAY_PAIRS_PER_DAY instead of O(N²).
        day_pairs_created = 0
        # K nearest neighbors per node (window of K consecutive nodes in time order).
        _K_NEAREST = 5
        for i, a in enumerate(node_ids):
            if day_pairs_created >= MAX_SAME_DAY_PAIRS_PER_DAY:
                break
            # Only link to the next K nodes in time order (avoids O(N²)).
            for b in node_ids[i + 1: i + 1 + _K_NEAREST]:
                if day_pairs_created >= MAX_SAME_DAY_PAIRS_PER_DAY:
                    break
                try:
                    if _safe_insert_edge(conn, a, b, "same-day"):
                        created += 1
                        day_pairs_created += 1
                except Exception:  # noqa: BLE001
                    log.warning(
                        "same-day: failed edge (%d → %d)", a, b, exc_info=True
                    )

    return created


# ──────────────────────────── mood-at ─────────────────────────────────────────


# ±1 hour tolerance for mood-at matching (mirrors happened-at).
_MOOD_AT_WINDOW_S: float = _HAPPENED_AT_WINDOW_S


def run_mood_at_linker(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    window_s: float = _MOOD_AT_WINDOW_S,
) -> int:
    """Link mood fact-nodes to event nodes when they occurred within ±window_s.

    Edge direction: mood_node → event_node (kind='mood-at').

    A MOOD node is any kind='fact' node whose data JSON carries a non-null
    "mood" field. Its event time is COALESCE(occurred_at, created_at): the real
    event timestamp when available, falling back to the graph-insertion time.

    EVENT nodes come from TWO sources:
      (a) meeting nodes — via the meetings table (start_time, node_id), exactly
          like the happened-at linker.
      (b) lifeos-events fact-nodes — nodes.domain='lifeos-events', whose event
          time is COALESCE(occurred_at, created_at).
      (c) relationships interaction fact-nodes — nodes.domain='relationships',
          same event-time expression. A relationships node carrying data.mood
          is both a mood node and an event candidate; self-links are guarded.

    Only meetings with a node_id (linked to a System-A node) are considered.
    Both mood nodes and events are bounded to the recent *window_days* window on
    their event timestamp.

    Returns the number of new 'mood-at' edges created.
    """
    cutoff = time.time() - window_days * 86400

    # Fetch mood fact-nodes: kind='fact' with a non-null data.mood, within window.
    mood_rows = conn.execute(
        "SELECT id, data, COALESCE(occurred_at, created_at) AS event_ts FROM nodes "
        "WHERE kind='fact' AND deleted_at IS NULL "
        "AND COALESCE(occurred_at, created_at) > ?",
        (cutoff,),
    ).fetchall()

    mood_nodes: list[tuple[int, float]] = []
    for row in mood_rows:
        try:
            data = json.loads(row["data"]) if row["data"] else {}
        except (json.JSONDecodeError, TypeError):
            continue
        if data.get("mood") is None:
            continue
        mood_nodes.append((int(row["id"]), float(row["event_ts"])))

    if not mood_nodes:
        return 0

    # Build the event list: (a) meeting nodes + (b) lifeos-events fact-nodes
    # + (c) relationships interaction fact-nodes ("mood 3 right after a
    # difficult conversation" becomes a traversable mood-at edge).
    events: list[tuple[int, float]] = []

    meetings = conn.execute(
        "SELECT node_id, start_time FROM meetings "
        "WHERE node_id IS NOT NULL AND start_time > ?",
        (cutoff,),
    ).fetchall()
    for m in meetings:
        events.append((int(m["node_id"]), float(m["start_time"])))

    event_nodes = conn.execute(
        "SELECT id, COALESCE(occurred_at, created_at) AS event_ts FROM nodes "
        "WHERE domain IN ('lifeos-events', 'relationships') AND deleted_at IS NULL "
        "AND COALESCE(occurred_at, created_at) > ?",
        (cutoff,),
    ).fetchall()
    for e in event_nodes:
        events.append((int(e["id"]), float(e["event_ts"])))

    if not events:
        return 0

    created = 0
    for mood_id, mood_ts in mood_nodes:
        for event_id, event_ts in events:
            if mood_id == event_id:
                continue
            if abs(mood_ts - event_ts) <= window_s:
                try:
                    if _safe_insert_edge(conn, mood_id, event_id, "mood-at"):
                        created += 1
                except Exception:  # noqa: BLE001
                    log.warning(
                        "mood-at: failed edge (%d → %d)", mood_id, event_id, exc_info=True
                    )

    return created


# ──────────────────────────── run_auto_linkers ────────────────────────────────


def run_auto_linkers(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    tz_name: str = "UTC",
) -> dict[str, int]:
    """Run all four cross-domain auto-linkers over the recent *window_days* window.

    Each linker is run in isolation; exceptions from one do not prevent the
    others from running.  Returns a summary dict with per-linker edge counts.

    Args:
        conn: Active sqlcipher3 connection to memory.db (System A).
        window_days: How many days back to look for candidates (default 90).
        tz_name: IANA timezone name passed to the same-day linker for calendar-day
            bucketing (default 'UTC').  Pass config.get('timezone', 'UTC') from
            the caller site so 'same day' means the user's local calendar day.

    Returns:
        {"happened_at": int, "involves_person": int, "same_day": int, "mood_at": int}
    """
    result: dict[str, int] = {
        "happened_at": 0,
        "involves_person": 0,
        "same_day": 0,
        "mood_at": 0,
    }

    try:
        result["happened_at"] = run_happened_at_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: happened_at failed", exc_info=True)

    try:
        result["mood_at"] = run_mood_at_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: mood_at failed", exc_info=True)

    try:
        result["involves_person"] = run_involves_person_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: involves_person failed", exc_info=True)

    try:
        result["same_day"] = run_same_day_linker(conn, window_days=window_days, tz_name=tz_name)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: same_day failed", exc_info=True)

    return result
