"""Tests for fact node creation from domain entries — Slice 2, tasks 2.3 (RED) / 2.4 (GREEN).

create_fact_node_for_interaction(interaction) must:
- Insert a kind='fact' node in nodes with raw_utterance (truncated to 120 chars) as label.
- Tag the node with domain='relationships'.
- Insert a row in domain_node_map linking (domain='relationships', entry_id, node_id).
- Enqueue embedding (trigger_embed_for_node called with the new node_id).
- Be idempotent: calling it again for the same entry_id does NOT create a second node.
"""
from __future__ import annotations

import time
from datetime import datetime, timezone
from unittest.mock import patch, MagicMock

import pytest


def _make_fake_interaction(
    *,
    iid: str = "01HXTEST00000000000000001",
    raw_utterance: str | None = "Hablé con María sobre el trabajo",
    title: str = "Conversación con María",
    body: str | None = "Detalles de la charla",
    person_id: str = "person-abc",
) -> MagicMock:
    """Build a minimal Interaction-like object for testing."""
    obj = MagicMock()
    obj.id = iid
    obj.raw_utterance = raw_utterance
    obj.title = title
    obj.body = body
    obj.person_id = person_id
    obj.ts = datetime.now(timezone.utc)
    return obj


def test_create_fact_node_inserts_node_with_raw_utterance(monkeypatch):
    """Task 2.3 RED: creates fact node with raw_utterance as label."""
    import axi.store as store
    from axi.store import create_fact_node_for_interaction, get_node_for_domain_entry

    interaction = _make_fake_interaction(raw_utterance="Hablé con María sobre el trabajo hoy en la oficina")

    with patch("axi.store.trigger_embed_for_node"):
        node_id = create_fact_node_for_interaction(interaction)

    assert node_id is not None
    conn = store._connect()
    row = conn.execute("SELECT kind, label, domain FROM nodes WHERE id = ?", (node_id,)).fetchone()
    assert row is not None, "node not found"
    assert row["kind"] == "fact"
    assert row["label"] == "Hablé con María sobre el trabajo hoy en la oficina"
    assert row["domain"] == "relationships"


def test_create_fact_node_truncates_raw_utterance_to_120_chars(monkeypatch):
    """Task 2.3 RED: raw_utterance longer than 120 chars is truncated to 120."""
    import axi.store as store
    from axi.store import create_fact_node_for_interaction

    long_utterance = "x" * 200
    interaction = _make_fake_interaction(raw_utterance=long_utterance)

    with patch("axi.store.trigger_embed_for_node"):
        node_id = create_fact_node_for_interaction(interaction)

    conn = store._connect()
    row = conn.execute("SELECT label FROM nodes WHERE id = ?", (node_id,)).fetchone()
    assert len(row["label"]) == 120


def test_create_fact_node_falls_back_to_title_when_no_raw_utterance(monkeypatch):
    """Task 2.3 RED: uses title when raw_utterance is None."""
    import axi.store as store
    from axi.store import create_fact_node_for_interaction

    interaction = _make_fake_interaction(raw_utterance=None, title="Charla con papá")

    with patch("axi.store.trigger_embed_for_node"):
        node_id = create_fact_node_for_interaction(interaction)

    conn = store._connect()
    row = conn.execute("SELECT label FROM nodes WHERE id = ?", (node_id,)).fetchone()
    assert row["label"] == "Charla con papá"


def test_create_fact_node_registers_domain_mapping(monkeypatch):
    """Task 2.3 RED: domain_node_map row is created linking interaction to node."""
    from axi.store import create_fact_node_for_interaction, get_node_for_domain_entry

    iid = "01HXTEST00000000000000002"
    interaction = _make_fake_interaction(iid=iid)

    with patch("axi.store.trigger_embed_for_node"):
        node_id = create_fact_node_for_interaction(interaction)

    mapped = get_node_for_domain_entry("relationships", iid)
    assert mapped == node_id


def test_create_fact_node_enqueues_embedding(monkeypatch):
    """Task 2.3 RED: trigger_embed_for_node is called with the new node_id."""
    from axi.store import create_fact_node_for_interaction

    interaction = _make_fake_interaction(iid="01HXTEST00000000000000003")

    with patch("axi.store.trigger_embed_for_node") as mock_trigger:
        node_id = create_fact_node_for_interaction(interaction)
        mock_trigger.assert_called_once_with(node_id)


def test_create_fact_node_idempotent_does_not_duplicate(monkeypatch):
    """Task 2.3 RED: calling create_fact_node_for_interaction twice for the same entry_id
    does NOT create a second node — returns the existing node_id."""
    import axi.store as store
    from axi.store import create_fact_node_for_interaction

    iid = "01HXTEST00000000000000004"
    interaction = _make_fake_interaction(iid=iid)

    with patch("axi.store.trigger_embed_for_node"):
        node_id_1 = create_fact_node_for_interaction(interaction)
        node_id_2 = create_fact_node_for_interaction(interaction)

    assert node_id_1 == node_id_2, "idempotent: second call must return same node_id"

    conn = store._connect()
    count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='fact' AND domain='relationships'"
    ).fetchone()[0]
    assert count == 1, f"expected 1 fact node, found {count}"
