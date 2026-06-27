"""Tests for the recall_memory tool (Layer 3 — Phase 2).

Covers:
- _RECALL_MEMORY_TOOL schema structure
- _recall_memory_tool_handler: empty query, disabled, success, no-match, never raises
- routing: non-image chat always uses ask_with_tools with recall_memory in tools
- web_search included/excluded based on web_research.is_enabled()
- handler uses graph_recall_tool_max_distance config value

Strict TDD (RED→GREEN). All external services are mocked.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _reset_web_research(monkeypatch):
    """Reset web_research globals before every test."""
    import lifeos.web as web_research
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)


@pytest.fixture
def chat_client(monkeypatch):
    """Minimal chat client with memory reset and nano disabled."""
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    return TestClient(dashboard.app)


# ---------------------------------------------------------------------------
# Part A — tool schema
# ---------------------------------------------------------------------------

def test_recall_memory_tool_schema_name():
    """_RECALL_MEMORY_TOOL must have function name 'recall_memory'."""
    from axi.dashboard import _RECALL_MEMORY_TOOL
    assert _RECALL_MEMORY_TOOL["type"] == "function"
    assert _RECALL_MEMORY_TOOL["function"]["name"] == "recall_memory"


def test_recall_memory_tool_schema_required_query():
    """_RECALL_MEMORY_TOOL must require the 'query' parameter."""
    from axi.dashboard import _RECALL_MEMORY_TOOL
    params = _RECALL_MEMORY_TOOL["function"]["parameters"]
    assert "query" in params["properties"]
    assert "query" in params["required"]


# ---------------------------------------------------------------------------
# Part A — handler: basic cases
# ---------------------------------------------------------------------------

def test_recall_memory_handler_empty_query():
    """Empty query string returns ok=False with an error key."""
    from axi.dashboard import _recall_memory_tool_handler
    result = _recall_memory_tool_handler({"query": ""})
    assert result["ok"] is False
    assert "error" in result


def test_recall_memory_handler_whitespace_query():
    """Whitespace-only query is treated as empty → ok=False."""
    from axi.dashboard import _recall_memory_tool_handler
    result = _recall_memory_tool_handler({"query": "   "})
    assert result["ok"] is False
    assert "error" in result


def test_recall_memory_handler_missing_query_key():
    """Missing query key (args={}) → ok=False, no exception."""
    from axi.dashboard import _recall_memory_tool_handler
    result = _recall_memory_tool_handler({})
    assert result["ok"] is False


def test_recall_memory_handler_graph_recall_disabled(monkeypatch):
    """When config graph_recall=False, handler returns ok=False immediately."""
    from axi import config
    from axi.dashboard import _recall_memory_tool_handler

    orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        False if key == "graph_recall" else orig_get(key, default)
    ))

    result = _recall_memory_tool_handler({"query": "presión arterial"})
    assert result["ok"] is False
    assert "error" in result


def test_recall_memory_handler_success(monkeypatch):
    """Non-empty recall block → ok=True, facts contains the block."""
    import axi.recall as _recall
    from axi import config
    from axi.dashboard import _recall_memory_tool_handler

    block = "MEMORIA RELEVANTE:\n- El 10 de junio: presión 120/80"
    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: block)

    orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else orig_get(key, default)
    ))

    result = _recall_memory_tool_handler({"query": "presión arterial"})
    assert result["ok"] is True
    assert result["facts"] == block
    assert result["query"] == "presión arterial"


def test_recall_memory_handler_no_match(monkeypatch):
    """Empty recall block (no match) → ok=False with 'note' key."""
    import axi.recall as _recall
    from axi import config
    from axi.dashboard import _recall_memory_tool_handler

    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: "")

    orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else orig_get(key, default)
    ))

    result = _recall_memory_tool_handler({"query": "glucosa"})
    assert result["ok"] is False
    assert "note" in result
    assert result["facts"] == ""


def test_recall_memory_handler_never_raises(monkeypatch):
    """Handler must not propagate exceptions from build_recall_block."""
    import axi.recall as _recall
    from axi import config
    from axi.dashboard import _recall_memory_tool_handler

    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("db gone")))

    orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else orig_get(key, default)
    ))

    result = _recall_memory_tool_handler({"query": "presión"})
    assert isinstance(result, dict)
    assert result["ok"] is False


# ---------------------------------------------------------------------------
# Part A — handler uses the looser tool threshold
# ---------------------------------------------------------------------------

def test_recall_memory_handler_uses_tool_max_distance(monkeypatch):
    """Handler must call build_recall_block with graph_recall_tool_max_distance."""
    import axi.recall as _recall
    from axi import config
    from axi.dashboard import _recall_memory_tool_handler

    captured_kw: list[dict] = []

    def _capturing_recall(*a, **kw):
        captured_kw.append(kw)
        return "MEMORIA RELEVANTE:\n- hecho"

    monkeypatch.setattr(_recall, "build_recall_block", _capturing_recall)

    orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall"
        else 0.92 if key == "graph_recall_tool_max_distance"
        else orig_get(key, default)
    ))

    _recall_memory_tool_handler({"query": "test"})

    assert len(captured_kw) == 1
    assert captured_kw[0]["max_distance"] == 0.92


# ---------------------------------------------------------------------------
# Part C — routing: recall_memory ALWAYS present on non-image turns
# ---------------------------------------------------------------------------

def test_routing_non_image_uses_ask_with_tools(monkeypatch):
    """Non-image chat turn must call brain.ask_with_tools, not brain.ask."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [],
        read_fn=lambda url: None,
        enabled_fn=lambda: False,  # web disabled
    )

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    # Isolate the general-brain recall path: the chat auto-router is a separate
    # layer (it makes its OWN classify brain.ask call and may route data
    # questions to a domain spec before this path runs). Bypass it so this test
    # exercises only the recall_memory tool wiring it is meant to cover —
    # autoroute has its own coverage in the chat_router tests.
    from axi import chat_router
    monkeypatch.setattr(chat_router, "route_and_handle", lambda *a, **kw: None)

    ask_called = []
    ask_with_tools_called = []

    monkeypatch.setattr(brain, "ask", lambda *a, **kw: ask_called.append(1) or "answer")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **kw: ask_with_tools_called.append(kw) or "answer")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "hola"})
    assert r.status_code == 200
    assert ask_called == [], "brain.ask must NOT be called on non-image turns"
    assert len(ask_with_tools_called) == 1


def test_routing_recall_tool_always_in_tools_web_disabled(monkeypatch):
    """When web is disabled, recall_memory is still in tools."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [],
        read_fn=lambda url: None,
        enabled_fn=lambda: False,
    )

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    # Bypass the auto-router (separate layer) so this test exercises only the
    # recall_memory tool wiring on the general-brain path. With autoroute live,
    # "qué presión tuve?" is routed to the Salud domain (which answers from the
    # health records directly) and never reaches this tool path — that is
    # correct product behavior, covered by the chat_router tests.
    from axi import chat_router
    monkeypatch.setattr(chat_router, "route_and_handle", lambda *a, **kw: None)

    captured: dict = {}

    def fake_ask_with_tools(prompt, **kw):
        captured.update(kw)
        return "answer"

    monkeypatch.setattr(brain, "ask_with_tools", fake_ask_with_tools)

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "qué presión tuve?"})
    assert r.status_code == 200

    tools = captured.get("tools", [])
    tool_names = [t["function"]["name"] for t in tools]
    assert "recall_memory" in tool_names
    assert "web_search" not in tool_names
    # tool_choice must stay "auto" — "required" would force the tool on every
    # casual turn, which is the spurious-call failure mode we want to avoid.
    assert captured.get("tool_choice") == "auto"
    # lang must be forwarded so recall/temporal context render in the user's language.
    assert "lang" in captured


def test_routing_recall_tool_present_web_enabled(monkeypatch):
    """When web is enabled, both recall_memory AND web_search are in tools."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [],
        read_fn=lambda url: None,
        enabled_fn=lambda: True,
    )

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    captured: dict = {}

    def fake_ask_with_tools(prompt, **kw):
        captured.update(kw)
        return "answer"

    monkeypatch.setattr(brain, "ask_with_tools", fake_ask_with_tools)

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "hola cómo estás"})
    assert r.status_code == 200

    tools = captured.get("tools", [])
    tool_names = [t["function"]["name"] for t in tools]
    assert "recall_memory" in tool_names
    assert "web_search" in tool_names


def test_routing_image_turn_uses_brain_ask(monkeypatch):
    """Image turn must still use brain.ask (not ask_with_tools)."""
    from axi import brain, dashboard

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    ask_called = []
    ask_with_tools_called = []

    monkeypatch.setattr(brain, "ask", lambda *a, **kw: ask_called.append(1) or "vision answer")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **kw: ask_with_tools_called.append(1) or "tools answer")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "qué ves?", "image_b64": "AAABBB"})
    assert r.status_code == 200
    assert len(ask_called) == 1, "brain.ask must be called for image turns"
    assert ask_with_tools_called == []


def test_routing_tool_handlers_include_recall_handler(monkeypatch):
    """tool_handlers dict passed to ask_with_tools must include 'recall_memory'."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [],
        read_fn=lambda url: None,
        enabled_fn=lambda: False,
    )

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    captured: dict = {}

    def fake_ask_with_tools(prompt, **kw):
        captured.update(kw)
        return "answer"

    monkeypatch.setattr(brain, "ask_with_tools", fake_ask_with_tools)

    tc = TestClient(dashboard.app)
    tc.post("/api/chat/ask", json={"text": "prueba"})

    handlers = captured.get("tool_handlers", {})
    assert "recall_memory" in handlers
    assert callable(handlers["recall_memory"])
