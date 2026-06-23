"""Tests for bounded backfill — Slice 2, tasks 2.7 (RED) / 2.8 (GREEN).

backfill_domain_fact_nodes(days=90, batch_size=50, sleep_s=0) must:
- Select interactions from the relationships domain within the last `days` days.
- Create fact nodes + domain_node_map entries for each.
- Skip already-mapped interactions (resumable).
- Respect the days window (interactions older than the window are excluded).
- Rate-limited: batch_size controls how many are processed per run.

backfill_similar_to_edges(threshold=0.85) must:
- For every node that has an embedding in vec_nodes, call check_and_create_similar_to_edges.
- Be idempotent.
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock, call

import pytest


def _make_interaction_dict(
    *,
    iid: str,
    raw_utterance: str | None = "utterance text",
    title: str = "Test Interaction",
    days_ago: int = 5,
) -> dict:
    ts = datetime.now(timezone.utc) - timedelta(days=days_ago)
    return {
        "id": iid,
        "raw_utterance": raw_utterance,
        "title": title,
        "body": None,
        "person_id": "person-001",
        "ts": ts,
    }


class _FakeInteraction:
    def __init__(self, d: dict):
        self.id = d["id"]
        self.raw_utterance = d.get("raw_utterance")
        self.title = d["title"]
        self.body = d.get("body")
        self.person_id = d["person_id"]
        self.ts = d["ts"]


def test_backfill_processes_recent_interactions(monkeypatch):
    """Task 2.7: backfill_domain_fact_nodes processes interactions within the window.

    Now delegates to backfill_all_domains(domains=["relationships"]), so we
    patch _fetch_domain_entries (the injectable seam) instead of the old
    _fetch_recent_interactions which is no longer on the hot path.
    """
    from axi.store import backfill_domain_fact_nodes, get_node_for_domain_entry

    fake_interactions = [
        _FakeInteraction(_make_interaction_dict(iid=f"01HX00000000000000000{i:02d}", days_ago=i))
        for i in range(1, 4)
    ]

    def _fake_fetch(domain, *, days, limit=None):
        if domain == "relationships":
            assert days == 90
            return fake_interactions
        return []

    with patch("axi.store.trigger_embed_for_node"), \
         patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        count = backfill_domain_fact_nodes(days=90, batch_size=50, sleep_s=0)

    assert count == 3, f"expected 3 processed, got {count}"


def test_backfill_skips_already_mapped_interactions(monkeypatch):
    """Task 2.7: already-mapped interactions are skipped (resumable).

    Delegates through backfill_all_domains → _fetch_domain_entries seam.
    """
    import axi.store as store
    from axi.store import backfill_domain_fact_nodes, upsert_domain_node_map

    # Pre-insert a node and register it in domain_node_map.
    conn = store._connect()
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) VALUES (?,?,?,?,?,?)",
        ("fact", "already mapped", "{}", "relationships", now, now),
    )
    conn.commit()
    existing_node_id = cur.lastrowid
    upsert_domain_node_map("relationships", "01HX-ALREADY", existing_node_id)

    already_mapped = _FakeInteraction(_make_interaction_dict(iid="01HX-ALREADY"))
    new_one = _FakeInteraction(_make_interaction_dict(iid="01HX-NEW-ONE"))

    def _fake_fetch(domain, *, days, limit=None):
        if domain == "relationships":
            return [already_mapped, new_one]
        return []

    with patch("axi.store.trigger_embed_for_node"), \
         patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        count = backfill_domain_fact_nodes(days=90, batch_size=50, sleep_s=0)

    assert count == 1, (
        f"expected 1 processed (skip already-mapped), got {count}"
    )


def test_backfill_respects_days_window(monkeypatch):
    """Task 2.7: interactions older than the window are excluded.

    Delegates through backfill_all_domains → _fetch_domain_entries seam.
    Verifies days is forwarded correctly to the fetch call.
    """
    from axi.store import backfill_domain_fact_nodes

    days_seen: list[int] = []

    def _fake_fetch(domain, *, days, limit=None):
        if domain == "relationships":
            days_seen.append(days)
        return []  # Simulate all filtered out at DB level.

    with patch("axi.store.trigger_embed_for_node"), \
         patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        count = backfill_domain_fact_nodes(days=90, batch_size=50, sleep_s=0)

    assert count == 0
    # The fetch must be called with days=90 so the DB query itself filters.
    assert 90 in days_seen, f"days=90 not forwarded to fetch; saw: {days_seen}"


def test_backfill_similar_to_edges_runs_for_embedded_nodes(monkeypatch):
    """Task 2.7 RED: backfill_similar_to_edges calls check_and_create for each embedded node."""
    import axi.store as store
    from axi.store import backfill_similar_to_edges

    conn = store._connect()
    now = time.time()

    # Insert 2 nodes with embeddings in vec_nodes.
    import struct
    blob = struct.pack("512f", *([0.1] * 512))
    for i in [10, 11]:
        conn.execute(
            "INSERT INTO nodes(id, kind, label, data, domain, created_at, updated_at, "
            "embedding, embedding_model, embedding_dim) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (i, "fact", f"node{i}", "{}", "test", now, now, blob, "test-model", 512),
        )
        conn.execute(
            "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
            (i, blob),
        )
    conn.commit()

    calls = []

    def mock_check(node_id, conn, threshold=0.85):
        calls.append(node_id)

    with patch("axi.store.check_and_create_similar_to_edges", side_effect=mock_check):
        backfill_similar_to_edges(threshold=0.85)

    assert 10 in calls, "node 10 not processed"
    assert 11 in calls, "node 11 not processed"
