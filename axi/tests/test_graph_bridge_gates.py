"""Tests for config-gated semantic graph bridging (graph_bridge_conversations /
graph_bridge_meetings).

TDD cycle:
  Task 1 — Default OFF: conversation not bridged (node_id=None, no kind='conversation' node)
  Task 2 — Flag ON:     conversation IS bridged (regression — old behavior preserved)
  Task 3 — Default OFF: process_meeting does NOT call bridge_meeting_node
  Task 4 — Flag ON:     process_meeting DOES call bridge_meeting_node
"""
from __future__ import annotations

import time
from pathlib import Path
from unittest.mock import MagicMock, patch, call


# ─────────────────────────────────────────────────────────────────────────────
# Task 1 — Default OFF: conversation not bridged
# ─────────────────────────────────────────────────────────────────────────────


def test_conversation_add_no_graph_node_when_bridge_off():
    """Default config (graph_bridge_conversations=False) → no kind='conversation' node created."""
    from axi import config, store
    from axi.memory import ConversationMemory

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_conversations": False,
        "timezone": "America/Mexico_City",
    }.get(key, default)):
        m = ConversationMemory()
        conv_id, node_id = m.add("hello graph gate", "hi back")

    # The conversation row must still be saved.
    assert conv_id > 0, "conversation row must be saved regardless of bridge flag"

    # No graph node should have been created.
    assert node_id is None, (
        f"node_id must be None when graph_bridge_conversations=False, got {node_id!r}"
    )

    # Double-check via DB: no kind='conversation' nodes at all.
    conn = store._connect()
    count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='conversation'"
    ).fetchone()[0]
    assert count == 0, (
        f"Expected 0 kind='conversation' nodes with bridge OFF, found {count}"
    )


def test_conversation_node_id_null_in_db_when_bridge_off():
    """conversations.node_id must be NULL when graph_bridge_conversations=False."""
    from axi import config, store
    from axi.memory import ConversationMemory

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_conversations": False,
        "timezone": "America/Mexico_City",
    }.get(key, default)):
        m = ConversationMemory()
        conv_id, _ = m.add("no bridge test", "response")

    conn = store._connect()
    row = conn.execute(
        "SELECT node_id FROM conversations WHERE id=?", (conv_id,)
    ).fetchone()
    assert row is not None, "conversation row should exist in DB"
    assert row[0] is None, (
        f"conversations.node_id must be NULL with bridge OFF, got {row[0]!r}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Task 2 — Flag ON: conversation IS bridged (regression)
# ─────────────────────────────────────────────────────────────────────────────


def test_conversation_add_creates_graph_node_when_bridge_on():
    """graph_bridge_conversations=True → node IS created and node_id > 0."""
    from axi import config, store
    from axi.memory import ConversationMemory

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_conversations": True,
        "timezone": "America/Mexico_City",
    }.get(key, default)):
        m = ConversationMemory()
        conv_id, node_id = m.add("opt-in bridge test", "response")

    assert conv_id > 0
    assert node_id is not None and node_id > 0, (
        f"node_id must be > 0 when graph_bridge_conversations=True, got {node_id!r}"
    )

    conn = store._connect()
    row = conn.execute(
        "SELECT node_id FROM conversations WHERE id=?", (conv_id,)
    ).fetchone()
    assert row[0] == node_id, (
        f"conversations.node_id={row[0]!r} must equal returned node_id={node_id!r}"
    )

    node = conn.execute(
        "SELECT kind FROM nodes WHERE id=?", (node_id,)
    ).fetchone()
    assert node is not None
    assert node[0] == "conversation", f"Expected kind='conversation', got {node[0]!r}"


# ─────────────────────────────────────────────────────────────────────────────
# Task 3 — Default OFF: process_meeting does NOT call bridge_meeting_node
# ─────────────────────────────────────────────────────────────────────────────


def _seed_meeting_for_process(conn, tmp_path: Path, *, status: str = "recording") -> int:
    """Insert a meeting row with a pre-existing segment so segments is non-empty."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO meetings(start_time, source, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (now, "test", str(tmp_path), status, now),
    )
    conn.commit()
    meeting_id = cur.lastrowid
    # Pre-insert a segment so process_meeting reads it back and segments is non-empty,
    # which means _hierarchical_summary (and thus the bridge decision) is reached.
    conn.execute(
        "INSERT INTO meeting_segments(meeting_id, channel, chunk_path, start_ms, end_ms, text, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (meeting_id, "system", "system-0.wav", 0, 10000, "Standup call started.", now),
    )
    conn.commit()
    return meeting_id


def test_process_meeting_no_bridge_when_flag_off(tmp_path, monkeypatch):
    """graph_bridge_meetings=False → bridge_meeting_node never called even with a summary."""
    import axi.meeting as meeting_mod
    from axi import config, store

    conn = store._connect()
    meeting_id = _seed_meeting_for_process(conn, tmp_path)

    # Patch config so graph_bridge_meetings=False and other keys have safe defaults.
    def _fake_config_get(key, default=None):
        return {
            "graph_bridge_meetings": False,
            "meeting_silence_rms": 0.005,
            "meeting_keep_raw_audio": True,
            "diarization_v2_enabled": False,
            "diarize_version": "auto",
        }.get(key, default)

    monkeypatch.setattr(config, "get", _fake_config_get)

    # Stub _hierarchical_summary to return a non-empty summary so the bridge
    # check is actually reached (the gate must run even when summary is present).
    monkeypatch.setattr(meeting_mod, "_hierarchical_summary", lambda *a, **kw: "Standup summary.")

    # Stub diarize_meeting so we don't need real audio.
    with patch("axi.diarize.diarize_meeting", return_value={}), \
         patch.object(meeting_mod, "bridge_meeting_node") as mock_bridge:
        # No WAV files in tmp_path → segments=[], summary="" unless stub overrides.
        # The stub above returns "Standup summary." unconditionally.
        # But _hierarchical_summary is only called when segments is non-empty OR…
        # let's also patch reindex_meeting_segments to avoid store side-effects.
        with patch.object(store, "reindex_meeting_segments", return_value=0):
            # Drive process_meeting with a stub transcriber and brain_ask.
            stub_transcriber = MagicMock(return_value={"text": "", "segments": []})
            stub_brain = MagicMock(return_value="Standup summary.")
            meeting_mod.process_meeting(meeting_id, stub_transcriber, stub_brain)

        mock_bridge.assert_not_called()


def test_process_meeting_bridge_called_when_flag_on(tmp_path, monkeypatch):
    """graph_bridge_meetings=True → bridge_meeting_node IS called when summary is available."""
    import axi.meeting as meeting_mod
    from axi import config, store

    conn = store._connect()
    meeting_id = _seed_meeting_for_process(conn, tmp_path)

    def _fake_config_get(key, default=None):
        return {
            "graph_bridge_meetings": True,
            "meeting_silence_rms": 0.005,
            "meeting_keep_raw_audio": True,
            "diarization_v2_enabled": False,
            "diarize_version": "auto",
        }.get(key, default)

    monkeypatch.setattr(config, "get", _fake_config_get)
    monkeypatch.setattr(meeting_mod, "_hierarchical_summary", lambda *a, **kw: "Sprint retro summary.")

    with patch("axi.diarize.diarize_meeting", return_value={}), \
         patch.object(meeting_mod, "bridge_meeting_node") as mock_bridge:
        with patch.object(store, "reindex_meeting_segments", return_value=0):
            stub_transcriber = MagicMock(return_value={"text": "", "segments": []})
            stub_brain = MagicMock(return_value="Sprint retro summary.")
            meeting_mod.process_meeting(meeting_id, stub_transcriber, stub_brain)

        # bridge_meeting_node should have been called with the meeting_id.
        mock_bridge.assert_called_once()
        args = mock_bridge.call_args[0]
        assert args[0] == meeting_id, (
            f"Expected bridge called with meeting_id={meeting_id}, got {args[0]!r}"
        )
