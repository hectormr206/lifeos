"""Tests for the conversational memory facade over store."""
from __future__ import annotations

import time

from axi.memory import ConversationMemory


def test_add_returns_conversation_id_node_id_none_by_default():
    """Default config (graph_bridge_conversations=False) → node_id is None."""
    m = ConversationMemory()
    conv_id, node_id = m.add("hola Axi", "hola Héctor")
    assert conv_id > 0
    # With graph_bridge_conversations=False (default), no graph node is created.
    assert node_id is None


def test_messages_returns_openai_format_oldest_first():
    m = ConversationMemory()
    m.add("primera", "respuesta uno")
    time.sleep(0.01)
    m.add("segunda", "respuesta dos")
    msgs = m.messages()
    assert len(msgs) == 4
    assert msgs[0] == {"role": "user", "content": "primera"}
    assert msgs[1] == {"role": "assistant", "content": "respuesta uno"}
    assert msgs[2] == {"role": "user", "content": "segunda"}


def test_clear_wipes_history_returns_count():
    m = ConversationMemory()
    m.add("a", "b")
    m.add("c", "d")
    n = m.clear()
    assert n == 2
    assert m.turn_count() == 0
    assert m.messages() == []


def test_turn_count_reflects_actual():
    m = ConversationMemory()
    assert m.turn_count() == 0
    m.add("x", "y")
    assert m.turn_count() == 1


def test_relevant_facts_orders_newest_first():
    """Facts about the same topic at different times: newest must come first."""
    from axi import store
    m = ConversationMemory()
    store.add_node("fact", "micrófono favorito es HyperX SoloCast", domain="setup")
    time.sleep(0.05)
    store.add_node("fact", "micrófono favorito es Huawei FreeClip", domain="setup")
    facts = m.relevant_facts("micrófono favorito")
    assert len(facts) == 2
    assert "Huawei" in facts[0]  # newest first
    assert "HyperX" in facts[1]


def test_relevant_facts_ignores_non_fact_kinds():
    """Conversation nodes must not leak into the facts retrieval."""
    m = ConversationMemory()
    m.add("hola micrófono", "qué tal")
    facts = m.relevant_facts("micrófono")
    assert facts == []
