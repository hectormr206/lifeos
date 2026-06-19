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
    now = ts or time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (kind, label, json.dumps(data or {}), domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind=? LIMIT 1",
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
        "SELECT COUNT(*) FROM edges WHERE from_id=? AND to_id=? AND kind='happened-at'",
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
        "SELECT COUNT(*) FROM edges WHERE from_id=? AND kind='involves-person'",
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
        "SELECT COUNT(*) FROM edges WHERE from_id=? AND to_id=? AND kind='involves-person'",
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
        "SELECT COUNT(*) FROM edges WHERE from_id=? AND to_id=? AND kind='same-day'",
        (nid1, nid2),
    ).fetchone()[0]
    count_rev = conn.execute(
        "SELECT COUNT(*) FROM edges WHERE from_id=? AND to_id=? AND kind='same-day'",
        (nid2, nid1),
    ).fetchone()[0]
    assert count_fwd + count_rev == 1


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
