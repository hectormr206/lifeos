"""Tests for meeting bridge: meeting.py bridge_meeting_node() sets meetings.node_id.

Phases covered:
  1.8.1 — After bridge_meeting_node runs, meetings.node_id is non-NULL.
  1.8.2 — Calling bridge_meeting_node twice (idempotent) does NOT create a second node.
  1.8.3 — Meeting node (kind='fact') is visible to run_same_day_linker.
  1.8.4 — Double-call race: exactly ONE node + node_id set (no orphan node).
"""
from __future__ import annotations

import time
from unittest.mock import patch

import pytest


def _seed_meeting(conn, *, summary: str = "", status: str = "done") -> int:
    """Insert a bare meeting row (without node_id) and return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO meetings(start_time, source, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (now, "test", "/tmp/test_meeting", status, now),
    )
    conn.commit()
    return cur.lastrowid


# ─── Phase 1.8.1 ────────────────────────────────────────────────────────────


def test_meeting_node_id_set_after_finalize(tmp_path):
    """1.8.1 — After bridge_meeting_node runs, meetings.node_id is non-NULL."""
    import axi.store as store
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    row_before = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    assert row_before[0] is None, "Precondition: node_id must be NULL before bridge call"

    bridge_meeting_node(meeting_id, "Team standup. Discussed sprint goals.")

    row_after = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    assert row_after[0] is not None, "node_id must be non-NULL after bridge_meeting_node"


def test_meeting_node_has_kind_fact(tmp_path):
    """1.8.1 — The created meeting node has kind='fact'."""
    import axi.store as store
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    bridge_meeting_node(meeting_id, "Sprint retrospective notes.")

    row = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid = row[0]
    assert nid is not None

    node = conn.execute("SELECT kind FROM nodes WHERE id=?", (nid,)).fetchone()
    assert node is not None
    assert node[0] == "fact", f"Meeting node kind must be 'fact', got {node[0]!r}"


# ─── Phase 1.8.2 ────────────────────────────────────────────────────────────


def test_meeting_bridge_idempotent():
    """1.8.2 — Calling bridge_meeting_node twice does NOT create a second node."""
    import axi.store as store
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    bridge_meeting_node(meeting_id, "First call.")
    row1 = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid1 = row1[0]

    bridge_meeting_node(meeting_id, "Second call — should be a no-op.")
    row2 = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid2 = row2[0]

    assert nid1 == nid2, "Second bridge call must not create a new node (idempotent)"

    count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE domain='meetings'"
    ).fetchone()[0]
    assert count == 1, f"Expected 1 meeting node, found {count}"


# ─── Phase 1.8.3 ────────────────────────────────────────────────────────────


def test_meeting_node_visible_to_same_day_linker():
    """1.8.3 — Meeting node (kind='fact') is in the same-day linker's pool."""
    import axi.store as store
    import sqlcipher3
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    conn.row_factory = sqlcipher3.Row

    meeting_id = _seed_meeting(conn)
    bridge_meeting_node(meeting_id, "Daily standup meeting notes.")

    row = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid = row["node_id"]

    cutoff = time.time() - 1
    result = conn.execute(
        "SELECT id FROM nodes WHERE kind='fact' AND created_at > ?",
        (cutoff,),
    ).fetchall()
    found_ids = {r["id"] for r in result}
    assert nid in found_ids, (
        f"Meeting node {nid} not found in same-day linker pool "
        f"(kind='fact' AND created_at > cutoff). Found: {found_ids}"
    )


# ─── Phase 1.8.4 — double-call race (FIX 2) ────────────────────────────────


def test_meeting_bridge_double_call_no_orphan_node():
    """1.8.4 — Two sequential bridge_meeting_node calls produce exactly ONE node.

    Simulates the recovery-path race: process_meeting called twice for the same
    meeting_id (once normally, once via recover_interrupted_meetings).  The
    serialized transaction guard must prevent duplicate nodes.
    """
    import axi.store as store
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    # Both calls use the same meeting_id (recovery scenario).
    bridge_meeting_node(meeting_id, "First summary.")
    bridge_meeting_node(meeting_id, "Recovery call — should be a no-op.")

    # node_id must be set exactly once.
    row = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    assert row[0] is not None, "node_id must be set after first call"

    # Exactly one node for this meeting in `nodes`.
    count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE data LIKE ?",
        (f'%"meeting_id": {meeting_id}%',),
    ).fetchone()[0]
    assert count == 1, (
        f"Expected exactly 1 node for meeting {meeting_id}, found {count} "
        "(duplicate/orphan node created by concurrent calls)"
    )
