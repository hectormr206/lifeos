"""Tests for cross-domain auto-linkers — Slice 3, tasks 3.3-3.9 (RED then GREEN).

Linkers tested:
  - happened_at: fact-node within ±1h of a meeting → 'happened-at' edge; outside → none; idempotent.
  - involves_person: fact-node with person_id → 'involves-person' edge to person node; idempotent.
  - same_day: fact-nodes sharing the same calendar day → 'same-day' edge; outside same day → none; idempotent.
  - run_auto_linkers: runs all three linkers together without error.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone, timedelta

import pytest


# ──────────────────────────── helpers ────────────────────────────────────────


def _insert_node(conn, kind="fact", label="test", domain="health", ts=None, data=None) -> int:
    """Insert a node through the production writer, then move its timestamps.

    This used to be a raw INSERT that omitted `uuid`. Nothing read that column,
    so the fixture got away with building a row shape production cannot
    produce (`store.add_node` has assigned a uuid at insert since task 5.14,
    and it is the only INSERT INTO nodes in the codebase). From PR6a on, an
    edge is resolved through its endpoints' uuids, so a uuid-less node makes
    every edge touching it invisible — which is how a fixture that models an
    impossible state turns into four "idempotency" failures.
    """
    import axi.store as _store

    now = ts or time.time()
    nid = _store.add_node(kind=kind, label=label, data=data or {}, domain=domain)
    conn.execute("UPDATE nodes SET created_at=?, updated_at=? WHERE id=?", (now, now, nid))
    conn.commit()
    return nid


def _insert_meeting(conn, start_time: float, title="Test meeting") -> int:
    cur = conn.execute(
        "INSERT INTO meetings(start_time, source, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (start_time, "manual", "/tmp/test", "done", time.time()),
    )
    conn.commit()
    return cur.lastrowid


def _edge_exists(conn, from_id: int, to_id: int, kind: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation=? LIMIT 1",
        (from_id, to_id, kind),
    ).fetchone()
    return row is not None


# ──────────────────── happened-at linker (task 3.3 RED) ──────────────────────


def test_happened_at_creates_edge_within_1h():
    """Fact-node with created_at within ±1h of meeting.start_time → happened-at edge."""
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    meeting_start = time.time()
    # Insert a meeting.
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    # Link the meetings table row to the node so the linker can find it.
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact-node created 30 min after meeting start (within ±1h window).
    fact_ts = meeting_start + 30 * 60
    fact_id = _insert_node(conn, kind="fact", label="Fact within window", domain="health", ts=fact_ts)

    created = run_happened_at_linker(conn)

    assert created >= 1
    # Edge direction: meeting_node → fact_node.
    assert _edge_exists(conn, meeting_node_id, fact_id, "happened-at")


def test_happened_at_no_edge_outside_1h():
    """Fact-node with created_at more than 1h away from any meeting → no edge."""
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact-node created 90 min after meeting start (outside ±1h window).
    fact_ts = meeting_start + 90 * 60
    fact_id = _insert_node(conn, kind="fact", label="Fact outside window", domain="health", ts=fact_ts)

    run_happened_at_linker(conn)

    assert not _edge_exists(conn, meeting_node_id, fact_id, "happened-at")


def test_happened_at_idempotent():
    """Running happened_at linker twice doesn't create duplicate edges."""
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    fact_ts = meeting_start + 20 * 60
    fact_id = _insert_node(conn, kind="fact", label="Fact idempotent", domain="health", ts=fact_ts)

    run_happened_at_linker(conn)
    run_happened_at_linker(conn)

    # Count edges of this kind between the pair.
    count = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='happened-at'",
        (meeting_node_id, fact_id),
    ).fetchone()[0]
    assert count == 1


# ─────────────────── involves-person linker (task 3.5 RED) ───────────────────


def test_involves_person_creates_edge_when_person_id_in_data():
    """Fact-node with person_id in data.person_id + person node in graph → involves-person edge."""
    import axi.store as store
    from axi.linkers import run_involves_person_linker

    conn = store._connect()

    # Insert a person node (kind='person').
    person_node_id = _insert_node(conn, kind="person", label="Alice", domain=None)

    # Insert a fact-node with person_id referencing alice.
    # The person_node_id is used as a mapping via person_id field in data.
    # In practice the person's name or ID is stored in data.person_id;
    # the linker maps fact.data.person_id → person node by matching
    # nodes(kind='person', data JSON containing matching id or label).
    # For this test, we use the simpler: person_id stored as node label.
    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Interaction with Alice",
        domain="relationships",
        data={"person_id": "alice-ulid-123"},
    )

    # Register the person node in a way the linker can find it.
    # The linker uses domain_node_map: map domain=relationships person entry
    # to the person node via the bridge table.
    conn.execute(
        "INSERT OR IGNORE INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("relationships_person", "alice-ulid-123", person_node_id, time.time()),
    )
    conn.commit()

    created = run_involves_person_linker(conn)

    assert created >= 1
    assert _edge_exists(conn, fact_id, person_node_id, "involves-person")


def test_involves_person_no_edge_without_matching_person():
    """Fact-node with an unknown person_id → no involves-person edge."""
    import axi.store as store
    from axi.linkers import run_involves_person_linker

    conn = store._connect()

    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Interaction with unknown",
        domain="relationships",
        data={"person_id": "unknown-person-999"},
    )

    created = run_involves_person_linker(conn)

    assert created == 0
    # No edge created.
    count = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='involves-person'",
        (fact_id,),
    ).fetchone()[0]
    assert count == 0


def test_involves_person_idempotent():
    """Running involves-person linker twice → still only one edge per pair."""
    import axi.store as store
    from axi.linkers import run_involves_person_linker

    conn = store._connect()

    person_node_id = _insert_node(conn, kind="person", label="Bob", domain=None)
    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Interaction with Bob",
        domain="relationships",
        data={"person_id": "bob-ulid-456"},
    )
    conn.execute(
        "INSERT OR IGNORE INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("relationships_person", "bob-ulid-456", person_node_id, time.time()),
    )
    conn.commit()

    run_involves_person_linker(conn)
    run_involves_person_linker(conn)

    count = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='involves-person'",
        (fact_id, person_node_id),
    ).fetchone()[0]
    assert count == 1


# ────────────────── same-day linker (task 3.7 RED) ───────────────────────────


def test_same_day_creates_edge_for_nodes_on_same_day():
    """Two fact-nodes created on the same calendar day → same-day edge."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Use today's date so the nodes fall within the default 90-day window.
    now = time.time()
    today_start = datetime.fromtimestamp(now, tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).timestamp()
    ts1 = today_start + 3600   # 1h after midnight UTC
    ts2 = today_start + 14400  # 4h after midnight UTC (same day)

    nid1 = _insert_node(conn, kind="fact", label="Morning fact", domain="health", ts=ts1)
    nid2 = _insert_node(conn, kind="fact", label="Afternoon fact", domain="health", ts=ts2)

    created = run_same_day_linker(conn)

    assert created >= 1
    assert _edge_exists(conn, nid1, nid2, "same-day") or _edge_exists(conn, nid2, nid1, "same-day")


def test_same_day_no_edge_for_nodes_on_different_days():
    """Fact-nodes on different calendar days → no same-day edge."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Use recent dates (within 90-day window) that span midnight UTC.
    now = time.time()
    today_end = datetime.fromtimestamp(now, tz=timezone.utc).replace(
        hour=23, minute=0, second=0, microsecond=0
    ).timestamp()
    next_day_start = today_end + 2 * 3600  # 2h into the next UTC day

    nid1 = _insert_node(conn, kind="fact", label="Day 1 fact", domain="health", ts=today_end)
    nid2 = _insert_node(conn, kind="fact", label="Day 2 fact", domain="health", ts=next_day_start)

    run_same_day_linker(conn)

    assert not _edge_exists(conn, nid1, nid2, "same-day")
    assert not _edge_exists(conn, nid2, nid1, "same-day")


def test_same_day_idempotent():
    """Running same-day linker twice → only one edge per pair."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Use today's date so the nodes fall within the 90-day window.
    now = time.time()
    today_start = datetime.fromtimestamp(now, tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).timestamp()
    base = today_start + 8 * 3600  # 8am UTC
    nid1 = _insert_node(conn, kind="fact", label="Morning", domain="relationships", ts=base)
    nid2 = _insert_node(conn, kind="fact", label="Evening", domain="relationships", ts=base + 6 * 3600)

    run_same_day_linker(conn)
    run_same_day_linker(conn)

    # At most 1 edge between nid1 and nid2 in either direction.
    count_fwd = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='same-day'",
        (nid1, nid2),
    ).fetchone()[0]
    count_rev = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='same-day'",
        (nid2, nid1),
    ).fetchone()[0]
    assert count_fwd + count_rev == 1


# ────────────────────── mood-at linker (MOOD-2 RED) ─────────────────────────


def test_mood_at_creates_edge_within_1h():
    """Mood fact-node within ±1h of a meeting → mood-at edge (mood → event)."""
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Mood fact-node 30 min after the meeting (within ±1h window).
    mood_ts = meeting_start + 30 * 60
    mood_id = _insert_node(
        conn, kind="fact", label="mood note", domain="spirituality",
        ts=mood_ts, data={"mood": 7},
    )

    created = run_mood_at_linker(conn)

    assert created >= 1
    # Edge direction: mood_node → event_node.
    assert _edge_exists(conn, mood_id, meeting_node_id, "mood-at")


def test_mood_at_no_edge_outside_1h():
    """Mood fact-node more than 1h away from any event → no mood-at edge."""
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Mood fact-node 90 min after the meeting (outside ±1h window).
    mood_ts = meeting_start + 90 * 60
    mood_id = _insert_node(
        conn, kind="fact", label="mood note far", domain="spirituality",
        ts=mood_ts, data={"mood": 3},
    )

    run_mood_at_linker(conn)

    assert not _edge_exists(conn, mood_id, meeting_node_id, "mood-at")


def test_mood_at_idempotent():
    """Running mood-at linker twice → only one edge per pair."""
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    mood_ts = meeting_start + 20 * 60
    mood_id = _insert_node(
        conn, kind="fact", label="mood note idem", domain="spirituality",
        ts=mood_ts, data={"mood": 6},
    )

    run_mood_at_linker(conn)
    run_mood_at_linker(conn)

    count = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='mood-at'",
        (mood_id, meeting_node_id),
    ).fetchone()[0]
    assert count == 1


def test_mood_at_links_to_lifeos_events_node():
    """Mood fact-node within ±1h of a lifeos-events fact-node → mood-at edge."""
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    event_ts = time.time()
    # A lifeos-events fact-node (no mood — it's the event, not the mood).
    event_id = _insert_node(
        conn, kind="fact", label="cumple de Juan", domain="lifeos-events", ts=event_ts,
    )

    # Mood fact-node 20 min after the event (within ±1h window).
    mood_ts = event_ts + 20 * 60
    mood_id = _insert_node(
        conn, kind="fact", label="mood note", domain="spirituality",
        ts=mood_ts, data={"mood": 8},
    )

    created = run_mood_at_linker(conn)

    assert created >= 1
    assert _edge_exists(conn, mood_id, event_id, "mood-at")


def test_mood_at_links_to_relationships_interaction():
    """Mood fact-node within ±1h of a relationships interaction → mood-at edge.

    'Mood 3 logged right after a difficult conversation' becomes traversable:
    relationships fact-nodes are event candidates alongside meetings and
    lifeos-events.
    """
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    interaction_ts = time.time()
    # A relationships interaction fact-node WITHOUT mood (the event side).
    interaction_id = _insert_node(
        conn, kind="fact", label="conversación difícil con Ana",
        domain="relationships", ts=interaction_ts,
    )

    # Spirituality mood fact-node 25 min later (within ±1h window).
    mood_ts = interaction_ts + 25 * 60
    mood_id = _insert_node(
        conn, kind="fact", label="mood note", domain="spirituality",
        ts=mood_ts, data={"mood": 3},
    )

    created = run_mood_at_linker(conn)

    assert created >= 1
    assert _edge_exists(conn, mood_id, interaction_id, "mood-at")


def test_mood_at_relationships_node_with_mood_cross_links():
    """Two relationships interactions within ±1h cross-link mood→event.

    A relationships node carrying data.mood is BOTH a mood node and an event
    candidate. Two distinct interactions an hour apart linking to each other
    ('conflict then quality_time') is intended behavior; self-links stay
    guarded by the mood_id == event_id check.
    """
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    t0 = time.time()
    a_id = _insert_node(
        conn, kind="fact", label="conflicto con Juan",
        domain="relationships", ts=t0, data={"mood": 3},
    )
    b_id = _insert_node(
        conn, kind="fact", label="tiempo de calidad con Juan",
        domain="relationships", ts=t0 + 40 * 60, data={"mood": 8},
    )

    created = run_mood_at_linker(conn)

    # Cross-links in both directions (each is a mood node seeing the other
    # as an event), but never a self-link.
    assert created >= 2
    assert _edge_exists(conn, a_id, b_id, "mood-at")
    assert _edge_exists(conn, b_id, a_id, "mood-at")
    assert not _edge_exists(conn, a_id, a_id, "mood-at")


def test_mood_at_ignores_facts_without_mood():
    """A fact-node with no data.mood is never treated as a mood node."""
    import axi.store as store
    from axi.linkers import run_mood_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, meeting_start)
    meeting_node_id = _insert_node(conn, kind="event", label="Meeting node", domain="meetings", ts=meeting_start)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact-node with NO mood in data, right at meeting time.
    plain_id = _insert_node(
        conn, kind="fact", label="plain fact", domain="health",
        ts=meeting_start + 5 * 60, data={"foo": "bar"},
    )

    run_mood_at_linker(conn)

    assert not _edge_exists(conn, plain_id, meeting_node_id, "mood-at")


# ─────────────── run_auto_linkers integration (task 3.9) ─────────────────────


def test_run_auto_linkers_runs_all_three():
    """run_auto_linkers() calls all three linkers without raising."""
    import axi.store as store
    from axi.linkers import run_auto_linkers

    conn = store._connect()

    # Insert minimal data so each linker has something to process.
    now = time.time()

    # For same-day: two nodes on same day.
    nid1 = _insert_node(conn, kind="fact", label="Node 1", domain="health", ts=now)
    nid2 = _insert_node(conn, kind="fact", label="Node 2", domain="health", ts=now + 3600)

    # For happened-at: a meeting + fact.
    mid = _insert_meeting(conn, now)
    meeting_node = _insert_node(conn, kind="event", label="Meeting", domain="meetings", ts=now)
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node, mid))
    conn.commit()

    fact_id = _insert_node(conn, kind="fact", label="Near meeting", domain="health", ts=now + 1800)

    # Should complete without raising.
    result = run_auto_linkers(conn)

    # Result is a dict with per-linker counts.
    assert isinstance(result, dict)
    assert "happened_at" in result
    assert "involves_person" in result
    assert "same_day" in result
    assert "mood_at" in result


# ──────────────────────────────────────────────────────────────────────────────
# FIX 6: same-day linker O(N²) cap
# ──────────────────────────────────────────────────────────────────────────────

def test_same_day_linker_bounded_fan_out():
    """FIX 6 RED: same-day linker must cap per-day edge fan-out to avoid O(N²).

    With N=30 nodes on the same day, an uncapped linker produces N*(N-1)/2 = 435 edges.
    After the cap (MAX_SAME_DAY_PAIRS_PER_DAY), the count must be <= the cap value.
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker, MAX_SAME_DAY_PAIRS_PER_DAY

    conn = store._connect()

    now = time.time()
    # All 30 nodes on the same UTC day.
    today_start = datetime.fromtimestamp(now, tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).timestamp()

    N = 30
    for i in range(N):
        _insert_node(conn, kind="fact", label=f"Fan-out node {i}", domain="finance", ts=today_start + i * 60)

    created = run_same_day_linker(conn)

    max_expected = N * (N - 1) // 2  # 435 without cap
    assert created <= MAX_SAME_DAY_PAIRS_PER_DAY, (
        f"same-day linker created {created} edges for {N} nodes on the same day, "
        f"exceeding MAX_SAME_DAY_PAIRS_PER_DAY={MAX_SAME_DAY_PAIRS_PER_DAY}. "
        "FIX 6 not applied — O(N²) fan-out uncapped."
    )


def test_same_day_linker_cap_exported():
    """FIX 6: MAX_SAME_DAY_PAIRS_PER_DAY must be importable from axi.linkers."""
    from axi.linkers import MAX_SAME_DAY_PAIRS_PER_DAY
    assert isinstance(MAX_SAME_DAY_PAIRS_PER_DAY, int)
    assert MAX_SAME_DAY_PAIRS_PER_DAY > 0


# ──────────────────────────────────────────────────────────────────────────────
# FIX 7a: conn.commit() in autocommit (linkers.py _safe_insert_edge)
# ──────────────────────────────────────────────────────────────────────────────

def test_safe_insert_edge_no_explicit_commit():
    """FIX 7a: _safe_insert_edge must NOT call conn.commit() in autocommit mode.

    isolation_level=None (autocommit) — conn.commit() is a no-op but breaks if
    the connection is ever nested inside _tx() (which begins an explicit txn).
    We verify that no commit() call is executed by checking there is no
    standalone 'conn.commit()' statement in the function body (outside comments/docstring).
    """
    import re
    import inspect
    from axi.linkers import _safe_insert_edge
    src = inspect.getsource(_safe_insert_edge)
    # Strip docstring from the search so docstring mentions don't trip the check.
    # Find the first line after the closing triple-quote of the docstring.
    body_start = src.find('"""', src.find('"""') + 3)
    body = src[body_start + 3:] if body_start != -1 else src
    # Look for an actual conn.commit() call (not in a comment or docstring).
    assert not re.search(r'^\s*conn\.commit\(\)', body, re.MULTILINE), (
        "_safe_insert_edge still calls conn.commit() — must be removed for "
        "correctness in autocommit mode and nested _tx() safety (FIX 7a)"
    )


# ──────────────────────────────────────────────────────────────────────────────
# PR5 "Expand" (design-schema.md, tasks.md 5.7): _safe_insert_edge dual-write
# ──────────────────────────────────────────────────────────────────────────────

def test_safe_insert_edge_dual_writes_src_dst_uuid():
    """Task 5.7 RED: linkers._safe_insert_edge (linkers.py:63) dual-writes
    src_uuid/dst_uuid alongside from_id/to_id, same as store.add_edge."""
    import axi.store as store
    from axi.linkers import _safe_insert_edge

    conn = store._connect()
    n1 = _insert_node(conn, kind="fact", label="Fact A")
    n2 = _insert_node(conn, kind="event", label="Event B")
    # _insert_node bypasses add_node's uuid-backfill path (PR4's documented,
    # deliberate gap — uuid is assigned on the next init_db() convergence).
    # Run that backfill here to mirror real sequencing before dual-writing.
    store.migrate_nodes_edges_sync_columns()

    created = _safe_insert_edge(conn, n1, n2, "happened-at")
    assert created is True

    src_uuid = conn.execute("SELECT uuid FROM nodes WHERE id=?", (n1,)).fetchone()[0]
    dst_uuid = conn.execute("SELECT uuid FROM nodes WHERE id=?", (n2,)).fetchone()[0]
    row = conn.execute(
        "SELECT src_uuid, dst_uuid FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='happened-at'",
        (n1, n2),
    ).fetchone()
    assert row["src_uuid"] == src_uuid
    assert row["dst_uuid"] == dst_uuid
    assert src_uuid is not None and dst_uuid is not None


# ─────────── PR6a: reader rewrite to src_uuid/dst_uuid/relation ───────────

def test_edge_exists_guard_resolves_through_endpoint_uuids():
    """RED for 6a.4: `linkers._edge_exists` is the duplicate guard in front of
    every auto-linker insert, so it must recognise an edge by the same
    endpoints the insert wrote — `src_uuid`/`dst_uuid`.

    This used to point the stored edge's integer `from_id` at a decoy while
    `src_uuid` still named the real source, so a guard reading the wrong column
    failed to see its own edge. PR8 deleted `from_id`, so the wrong column
    cannot be read. The consequence that mattered is asserted directly instead:
    the guard recognises the edge it wrote, `_safe_insert_edge` declines to add
    a second one — and moving `src_uuid` makes the guard correctly stop
    recognising it, proving that column is what it actually reads. Get this
    wrong and the linker appends a duplicate on every daemon pass, forever.
    """
    from axi import linkers, store

    src = store.add_node("fact", "nota A")
    dst = store.add_node("fact", "nota B")
    decoy = store.add_node("fact", "señuelo")
    eid = store.add_edge(src, dst, "same-day")
    c = store._connect()

    assert linkers._edge_exists(c, src, dst, "same-day") is True
    assert linkers._safe_insert_edge(c, src, dst, "same-day") is False
    assert c.execute("SELECT COUNT(*) FROM edges").fetchone()[0] == 1

    c.execute(
        "UPDATE edges SET src_uuid=(SELECT uuid FROM nodes WHERE id=?) WHERE id=?",
        (decoy, eid),
    )
    assert linkers._edge_exists(c, src, dst, "same-day") is False
    assert linkers._edge_exists(c, decoy, dst, "same-day") is True


def test_edge_exists_identical_to_pre_rewrite_query(pr6a_graph):
    """6a.4's "identical results" on the seeded fixture: every ordered pair
    and kind, compared against the literal pre-rewrite guard."""
    from axi import linkers, store

    c = store._connect()
    # The ghost endpoint is excluded and pinned separately in
    # test_identity.py::test_edge_exists_disagrees_only_for_an_endpoint_id_that_no_longer_exists
    # — it is the one input where the rewrite deliberately does not agree.
    ids = [i for k, i in pr6a_graph.items() if k != "ghost"]
    for a in ids:
        for b in ids:
            for kind in ("about", "mentions", "involves", "esposa", "same-day"):
                old = c.execute(
                    "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation=? LIMIT 1",
                    (a, b, kind),
                ).fetchone() is not None
                assert linkers._edge_exists(c, a, b, kind) is old, (
                    f"_edge_exists({a}, {b}, {kind!r}) diverged from the "
                    f"pre-rewrite guard"
                )


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — tombstone filters in the auto-linkers (task 7.9/7.10).
#
# The linkers run unattended on every daemon pass. If they keep seeing
# tombstoned nodes they will quietly rebuild the graph around memories the
# user deleted, and nothing surfaces that.
# ═══════════════════════════════════════════════════════════════════════════


def _tombstone_node_row(nid: int) -> None:
    from axi import store

    store._connect().execute(  # noqa: SLF001
        "UPDATE nodes SET deleted_at=?, updated_at=? WHERE id=?",
        (time.time(), time.time(), nid),
    )


def test_linkers_edge_exists_ignores_a_tombstoned_edge():
    """The duplicate guard must not let a deleted edge block re-linking."""
    from axi import linkers, store

    a = store.add_node("fact", "desayuno")
    b = store.add_node("fact", "junta")
    eid = store.add_edge(a, b, "same-day")
    c = store._connect()  # noqa: SLF001
    assert linkers._edge_exists(c, a, b, "same-day") is True

    c.execute(
        "UPDATE edges SET deleted_at=?, updated_at=? WHERE id=?",
        (time.time(), time.time(), eid),
    )
    assert linkers._edge_exists(c, a, b, "same-day") is False


def test_same_day_linker_skips_tombstoned_fact_nodes():
    """A deleted fact must not be re-attached to the day it belonged to."""
    from axi import linkers, store

    now = time.time()
    a = store.add_node("fact", "desayuno", occurred_at=now)
    b = store.add_node("fact", "junta", occurred_at=now + 60)
    doomed = store.add_node("fact", "cosa borrada", occurred_at=now + 120)
    _tombstone_node_row(doomed)

    c = store._connect()  # noqa: SLF001
    linkers.run_same_day_linker(conn=c)

    doomed_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (doomed,)).fetchone()[0]
    touching = c.execute(
        "SELECT id FROM edges WHERE src_uuid=? OR dst_uuid=?",
        (doomed_uuid, doomed_uuid),
    ).fetchall()
    assert touching == [], (
        f"the same-day linker rebuilt edges around a deleted memory: {touching}"
    )
    # …while the live pair still gets linked.
    assert linkers._edge_exists(c, a, b, "same-day") or linkers._edge_exists(c, b, a, "same-day")
