"""Tests for the config-gated chat fact extractor (graph_bridge_chat_facts).

TDD cycle:
  Task 1 — Default OFF: extract_and_store returns 0, creates NO kind='fact' node,
            and brain_ask is NOT called (avoids the expensive LLM call entirely).
  Task 2 — Flag ON (regression): extraction runs as before — brain_ask IS called,
            kind='fact' node IS created, count returned is 1.
"""
from __future__ import annotations

from unittest.mock import patch, MagicMock


# ─────────────────────────────────────────────────────────────────────────────
# Task 1 — Default OFF: no LLM call, no node, returns 0
# ─────────────────────────────────────────────────────────────────────────────


def test_extract_and_store_default_off_returns_zero():
    """With default config (graph_bridge_chat_facts=False), extract_and_store returns 0."""
    from axi import config
    from axi.extractor import extract_and_store

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_chat_facts": False,
    }.get(key, default)):
        result = extract_and_store("user says something", "axi responds", None)

    assert result == 0, (
        f"extract_and_store must return 0 when graph_bridge_chat_facts=False, got {result!r}"
    )


def test_extract_and_store_default_off_no_fact_nodes():
    """With default config, NO kind='fact' node is created in the graph."""
    from axi import config, store
    from axi.extractor import extract_and_store

    conn = store._connect()
    count_before = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='fact'"
    ).fetchone()[0]

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_chat_facts": False,
    }.get(key, default)):
        extract_and_store("user says something", "axi responds", None)

    count_after = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='fact'"
    ).fetchone()[0]

    assert count_after == count_before, (
        f"Expected no new kind='fact' nodes when graph_bridge_chat_facts=False, "
        f"but count went from {count_before} to {count_after}"
    )


def test_extract_and_store_default_off_brain_ask_not_called():
    """With default config, brain_ask is NOT called (LLM call is skipped entirely)."""
    from axi import config
    from axi.extractor import extract_and_store

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_chat_facts": False,
    }.get(key, default)), \
         patch("axi.extractor.brain_ask") as mock_brain:
        extract_and_store("user says something", "axi responds", None)

    mock_brain.assert_not_called(), (
        "brain_ask must NOT be called when graph_bridge_chat_facts=False "
        "— the LLM call is expensive and must be gated out entirely"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Task 2 — Flag ON: extraction runs, brain_ask called, fact node created
# ─────────────────────────────────────────────────────────────────────────────


def test_extract_and_store_flag_on_calls_brain_ask():
    """When graph_bridge_chat_facts=True, brain_ask IS called."""
    from axi import config
    from axi.extractor import extract_and_store

    fake_brain_response = '{"facts": [{"kind": "preference", "label": "Héctor prefers dark mode", "data": {}, "domain": "setup"}]}'

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_chat_facts": True,
    }.get(key, default)), \
         patch("axi.extractor.brain_ask", return_value=fake_brain_response) as mock_brain:
        result = extract_and_store("I prefer dark mode", "Got it!", None)

    mock_brain.assert_called_once()
    assert result == 1, (
        f"extract_and_store must return 1 when one fact is extracted with flag ON, got {result!r}"
    )


def test_extract_and_store_flag_on_creates_fact_node():
    """When graph_bridge_chat_facts=True, a kind='fact' node IS created in the graph."""
    from axi import config, store
    from axi.extractor import extract_and_store

    conn = store._connect()
    count_before = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='fact'"
    ).fetchone()[0]

    fake_brain_response = '{"facts": [{"kind": "setup", "label": "Héctor uses NeoVim as editor", "data": {}, "domain": "setup"}]}'

    with patch.object(config, "get", side_effect=lambda key, default=None: {
        "graph_bridge_chat_facts": True,
    }.get(key, default)), \
         patch("axi.extractor.brain_ask", return_value=fake_brain_response):
        extract_and_store("I use NeoVim", "Great choice!", None)

    count_after = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE kind='fact'"
    ).fetchone()[0]

    assert count_after == count_before + 1, (
        f"Expected 1 new kind='fact' node when graph_bridge_chat_facts=True, "
        f"count went from {count_before} to {count_after}"
    )
