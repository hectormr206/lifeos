"""Cross-domain auto-linkers for the Axi semantic memory graph — Slice 3.

These functions create edges between existing System-A nodes using data already
present in memory.db.  All linkers are IDEMPOTENT (SELECT-before-INSERT) and
bounded to a recent window to avoid full-table scans.

Linkers implemented:
  - run_happened_at_linker   : meeting node → fact node when fact.created_at ∈ [meeting.start_time ± 1h]
  - run_involves_person_linker: fact node → person node when fact.data.person_id is bridged via domain_node_map
  - run_same_day_linker      : fact node ↔ fact node when both share the same UTC calendar day

Each function:
  - Accepts a live sqlcipher3 connection (same connection the caller uses).
  - Returns an int count of NEW edges created this run.
  - Logs warnings on per-row failures but never propagates exceptions.

run_auto_linkers(conn, *, window_days=90):
  - Runs all three linkers over a recent bounded window.
  - Returns {happened_at: int, involves_person: int, same_day: int}.
"""
from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone

log = logging.getLogger("axi.linkers")

# ±1 hour tolerance for happened-at matching.
_HAPPENED_AT_WINDOW_S: float = 3600.0

# Look-back window for same-day and happened-at linkers (seconds).
_DEFAULT_WINDOW_DAYS: int = 90


def _edge_exists(conn, from_id: int, to_id: int, kind: str) -> bool:
    """Return True if an edge of *kind* from *from_id* to *to_id* already exists."""
    row = conn.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind=? LIMIT 1",
        (from_id, to_id, kind),
    ).fetchone()
    return row is not None


def _safe_insert_edge(conn, from_id: int, to_id: int, kind: str) -> bool:
    """Insert edge if not already present. Returns True if a new edge was created."""
    if _edge_exists(conn, from_id, to_id, kind):
        return False
    conn.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at) VALUES (?, ?, ?, ?, ?)",
        (from_id, to_id, kind, "{}", time.time()),
    )
    conn.commit()
    return True


# ──────────────────────────── happened-at ─────────────────────────────────────


def run_happened_at_linker(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    window_s: float = _HAPPENED_AT_WINDOW_S,
) -> int:
    """Link fact-nodes to meeting nodes when fact.created_at ∈ [meeting.start_time ± window_s].

    Edge direction: meeting_node → fact_node (kind='happened-at').

    Only meetings that have a node_id (linked to a System-A node) are considered.
    Only fact-nodes in the recent *window_days* days are processed.

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

    # Fetch recent fact-nodes.
    fact_nodes = conn.execute(
        "SELECT id, created_at FROM nodes "
        "WHERE kind='fact' AND created_at > ?",
        (cutoff,),
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
            fact_ts = float(fact["created_at"])
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
        "WHERE domain='relationships' AND kind='fact' AND created_at > ?",
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
) -> int:
    """Link pairs of fact-nodes that share the same UTC calendar day.

    This is a time-proximity linker: two facts on the same day are likely
    contextually related even without semantic similarity.  Edges are created
    with kind='same-day'.

    Only fact-nodes in the recent *window_days* window are processed.
    Within that window, nodes are grouped by UTC date string (YYYY-MM-DD).
    For each group, every ordered pair (lower_id, higher_id) gets one edge.
    Self-links are excluded.  Idempotent via SELECT-before-INSERT.

    Design note: We choose same-day over mood-correlates-with because
    health.Entry has no explicit mood field (mood_pre/mood_post live on
    Interaction in the relationships domain). The same-day linker is simpler,
    fully defensible, and uses only System-A data — no cross-DB read required.

    Returns the number of new 'same-day' edges created.
    """
    cutoff = time.time() - window_days * 86400

    rows = conn.execute(
        "SELECT id, created_at FROM nodes "
        "WHERE kind='fact' AND created_at > ? "
        "ORDER BY created_at ASC",
        (cutoff,),
    ).fetchall()

    # Group by UTC date string.
    by_day: dict[str, list[int]] = {}
    for row in rows:
        ts = float(row["created_at"])
        day_key = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")
        by_day.setdefault(day_key, []).append(int(row["id"]))

    created = 0
    for day_key, node_ids in by_day.items():
        if len(node_ids) < 2:
            continue
        # Create edges for every ordered pair (a, b) with a < b (avoids duplicates).
        for i in range(len(node_ids)):
            for j in range(i + 1, len(node_ids)):
                a, b = node_ids[i], node_ids[j]
                try:
                    if _safe_insert_edge(conn, a, b, "same-day"):
                        created += 1
                except Exception:  # noqa: BLE001
                    log.warning(
                        "same-day: failed edge (%d → %d)", a, b, exc_info=True
                    )

    return created


# ──────────────────────────── run_auto_linkers ────────────────────────────────


def run_auto_linkers(
    conn,
    *,
    window_days: int = _DEFAULT_WINDOW_DAYS,
) -> dict[str, int]:
    """Run all three cross-domain auto-linkers over the recent *window_days* window.

    Each linker is run in isolation; exceptions from one do not prevent the
    others from running.  Returns a summary dict with per-linker edge counts.

    Args:
        conn: Active sqlcipher3 connection to memory.db (System A).
        window_days: How many days back to look for candidates (default 90).

    Returns:
        {"happened_at": int, "involves_person": int, "same_day": int}
    """
    result: dict[str, int] = {
        "happened_at": 0,
        "involves_person": 0,
        "same_day": 0,
    }

    try:
        result["happened_at"] = run_happened_at_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: happened_at failed", exc_info=True)

    try:
        result["involves_person"] = run_involves_person_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: involves_person failed", exc_info=True)

    try:
        result["same_day"] = run_same_day_linker(conn, window_days=window_days)
    except Exception:  # noqa: BLE001
        log.warning("run_auto_linkers: same_day failed", exc_info=True)

    return result
