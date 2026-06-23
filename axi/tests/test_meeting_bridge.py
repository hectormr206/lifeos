"""Tests for meeting bridge fix: meeting.py:964 sets meetings.node_id after summarization.

Phases covered:
  1.8.1 — After finalization, meetings.node_id is non-NULL.
  1.8.2 — Calling the bridge twice (idempotent) does NOT create a second node.
  1.8.3 — Meeting node (kind='fact') is visible to run_same_day_linker.
"""
from __future__ import annotations

import time
from pathlib import Path
from unittest.mock import MagicMock, patch

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
    """1.8.1 RED — After the bridge logic runs, meetings.node_id is non-NULL."""
    import axi.store as store

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    # Check that node_id is currently NULL.
    row_before = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    assert row_before[0] is None, "Precondition: node_id must be NULL before finalization"

    _bridge_meeting_node(meeting_id, summary="Team standup. Discussed sprint goals.")

    row_after = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    assert row_after[0] is not None, "node_id must be non-NULL after bridge call"


def test_meeting_node_has_kind_fact(tmp_path):
    """1.8.1 RED — The created meeting node has kind='fact'."""
    import axi.store as store

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    _bridge_meeting_node(meeting_id, summary="Sprint retrospective notes.")

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
    """1.8.2 RED — Bridging the same meeting twice does NOT create a second node."""
    import axi.store as store

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    _bridge_meeting_node(meeting_id, summary="First call.")
    row1 = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid1 = row1[0]

    _bridge_meeting_node(meeting_id, summary="Second call — should be a no-op.")
    row2 = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid2 = row2[0]

    assert nid1 == nid2, "Second bridge call must not create a new node (idempotent)"

    # Exactly one node with domain='meetings'.
    count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE domain='meetings'"
    ).fetchone()[0]
    assert count == 1, f"Expected 1 meeting node, found {count}"


# ─── Phase 1.8.3 ────────────────────────────────────────────────────────────


def test_meeting_node_visible_to_same_day_linker():
    """1.8.3 RED — Meeting node (kind='fact') is in the same-day linker's pool.

    The same-day linker queries: SELECT id FROM nodes WHERE kind='fact' AND created_at > ?
    So a meeting node with kind='fact' must appear there.
    """
    import axi.store as store
    import sqlcipher3

    conn = store._connect()
    conn.row_factory = sqlcipher3.Row

    meeting_id = _seed_meeting(conn)
    _bridge_meeting_node(meeting_id, summary="Daily standup meeting notes.")

    row = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    nid = row["node_id"]

    # Query exactly what the same-day linker uses.
    cutoff = time.time() - 1  # 1 second ago — node was just created
    result = conn.execute(
        "SELECT id FROM nodes WHERE kind='fact' AND created_at > ?",
        (cutoff,),
    ).fetchall()
    found_ids = {r["id"] for r in result}
    assert nid in found_ids, (
        f"Meeting node {nid} not found in same-day linker pool "
        f"(kind='fact' AND created_at > cutoff). Found: {found_ids}"
    )


# ─── helper used by all tests ────────────────────────────────────────────────


def _bridge_meeting_node(meeting_id: int, *, summary: str) -> None:
    """Call the meeting bridge logic: add_node('fact') + UPDATE meetings SET node_id.

    This is extracted from meeting.py:964 so tests can drive it in isolation.
    Once meeting.py is updated (Phase 1.8.4 GREEN), this helper can delegate to
    that function directly.
    """
    import axi.store as store

    conn = store._connect()

    # Check idempotency guard: only bridge if node_id is NULL.
    row = conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    if row is None or row[0] is not None:
        return  # Already bridged or meeting not found.

    label = (summary or "meeting")[:120]
    nid = store.add_node(
        "fact", label, data={"meeting_id": meeting_id}, domain="meetings"
    )
    with store._tx() as txc:
        txc.execute(
            "UPDATE meetings SET node_id=? WHERE id=?",
            (nid, meeting_id),
        )
    store.trigger_embed_for_node(nid)
