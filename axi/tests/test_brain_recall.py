"""Tests for brain.py graph-recall injection (Layer 3).

Covers:
  1-4: _build_messages recall injection (existing)
  5:   ask_with_tools injects recall in FIRST call exactly once (FIX 1)
  6:   ask_with_tools skips recall when graph_recall=False (FIX 1)
  7:   4B retry path does NOT trigger a second recall embed (FIX 3)
  8:   tuteo restraint in Spanish (FIX 7)
"""
from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _invoke_build_messages(
    monkeypatch,
    prompt: str = "pregunta de prueba",
    system: str = "eres Axi",
    lang: str | None = None,
    *,
    recall_return: str = "",
    graph_recall_enabled: bool = True,
):
    """Call brain._build_messages with controlled dependencies."""
    from axi import config, brain

    # Patch config.get to control graph_recall flag
    _orig_config_get = config.get

    def _mock_config_get(key, default=None):
        if key == "graph_recall":
            return graph_recall_enabled
        return _orig_config_get(key, default)

    monkeypatch.setattr(config, "get", _mock_config_get)

    # Patch recall.build_recall_block
    import axi.recall as _recall
    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: recall_return)

    return brain._build_messages(prompt, system, lang=lang)


# ---------------------------------------------------------------------------
# 1. Non-empty recall block → system contains MEMORIA RELEVANTE + restraint
# ---------------------------------------------------------------------------

def test_build_messages_includes_recall_block_when_non_empty(monkeypatch):
    """When recall block is non-empty, system must contain it and the restraint."""
    msgs = _invoke_build_messages(
        monkeypatch,
        recall_return="MEMORIA RELEVANTE (usala solo si responde la pregunta):\n- El 11 de junio: dormí 5h",
        graph_recall_enabled=True,
    )

    system_content = msgs[0]["content"]
    assert "MEMORIA RELEVANTE" in system_content
    # Restraint must also be present
    assert "Los recuerdos de arriba" in system_content or "memories above" in system_content.lower()


# ---------------------------------------------------------------------------
# 2. Empty recall block → system unchanged (exact f"{system}\n\n{_tc}" format)
# ---------------------------------------------------------------------------

def test_build_messages_unchanged_when_recall_empty(monkeypatch):
    """When recall block is '', _build_messages behaves exactly as before (no extra sections)."""
    from axi import brain

    system = "eres Axi"
    msgs = _invoke_build_messages(
        monkeypatch,
        system=system,
        recall_return="",
        graph_recall_enabled=True,
    )

    system_content = msgs[0]["content"]
    # Must NOT contain recall or restraint sections
    assert "MEMORIA RELEVANTE" not in system_content
    assert "RELEVANT MEMORY" not in system_content
    assert "Los recuerdos de arriba" not in system_content
    assert "memories above" not in system_content.lower()


# ---------------------------------------------------------------------------
# 3. graph_recall=False → recall skipped even if block would be non-empty
# ---------------------------------------------------------------------------

def test_build_messages_skips_recall_when_graph_recall_false(monkeypatch):
    """When config graph_recall=False, recall is not injected even if block is non-empty."""
    msgs = _invoke_build_messages(
        monkeypatch,
        recall_return="MEMORIA RELEVANTE:\n- El 11 de junio: dormí 5h",
        graph_recall_enabled=False,
    )

    system_content = msgs[0]["content"]
    assert "MEMORIA RELEVANTE" not in system_content
    assert "Los recuerdos de arriba" not in system_content


# ---------------------------------------------------------------------------
# 4. lang='en' → English restraint
# ---------------------------------------------------------------------------

def test_build_messages_en_uses_english_restraint(monkeypatch):
    """When lang='en', the restraint line uses English, not Spanish."""
    msgs = _invoke_build_messages(
        monkeypatch,
        lang="en",
        recall_return="RELEVANT MEMORY (use only if it answers the question):\n- On June 11: slept 5h",
        graph_recall_enabled=True,
    )

    system_content = msgs[0]["content"]
    assert "memories above" in system_content.lower() or "The memories above" in system_content
    assert "Los recuerdos de arriba" not in system_content


# ---------------------------------------------------------------------------
# FIX 7 — tuteo restraint: no voseo in Spanish restraint line
# ---------------------------------------------------------------------------

def test_build_messages_spanish_restraint_uses_tuteo(monkeypatch):
    """Spanish restraint must use tuteo (Usa, cita, ignóralos) not voseo."""
    msgs = _invoke_build_messages(
        monkeypatch,
        recall_return="MEMORIA RELEVANTE:\n- El 11 de junio: dormí 5h",
        graph_recall_enabled=True,
    )
    system_content = msgs[0]["content"]
    assert "Los recuerdos de arriba" in system_content
    # tuteo forms
    assert "Usa " in system_content
    assert "cita " in system_content
    assert "ignóralos" in system_content
    # voseo forms must NOT be present
    assert "Usá " not in system_content
    assert "citá " not in system_content
    assert "ignoralos" not in system_content


# ---------------------------------------------------------------------------
# FIX 1 — ask_with_tools injects MEMORIA RELEVANTE exactly once
# ---------------------------------------------------------------------------

def _make_fake_response(content: str = "respuesta") -> dict:
    """Build a minimal fake llama-server chat completion response."""
    import json
    return {
        "choices": [
            {
                "message": {"role": "assistant", "content": content, "tool_calls": []},
                "finish_reason": "stop",
            }
        ],
        "usage": {},
    }


def test_ask_with_tools_injects_recall_in_first_call(monkeypatch):
    """ask_with_tools must inject MEMORIA RELEVANTE into the system of its FIRST model call."""
    import json
    import axi.recall as _recall
    from axi import config, brain

    # Stub recall to return a non-empty block
    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: "MEMORIA RELEVANTE:\n- El 11 de junio: dormí 5h")

    # Control graph_recall=True
    _orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else _orig_get(key, default)
    ))

    captured_payloads: list[dict] = []

    def _fake_post(payload_obj, timeout, endpoint=brain.ENDPOINT):
        captured_payloads.append(payload_obj)
        return _make_fake_response()

    monkeypatch.setattr(brain, "_post_chat_completion", _fake_post)

    brain.ask_with_tools(
        "qué dormí ayer?",
        tools=[],
        tool_handlers={},
    )

    # First (and only) call should have MEMORIA RELEVANTE in system message
    assert len(captured_payloads) >= 1
    first_messages = captured_payloads[0]["messages"]
    system_content = first_messages[0]["content"]
    assert "MEMORIA RELEVANTE" in system_content


def test_ask_with_tools_recall_not_injected_when_disabled(monkeypatch):
    """ask_with_tools must NOT inject recall when graph_recall=False."""
    import axi.recall as _recall
    from axi import config, brain

    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: "MEMORIA RELEVANTE:\n- hecho")

    _orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        False if key == "graph_recall" else _orig_get(key, default)
    ))

    captured_payloads: list[dict] = []

    def _fake_post(payload_obj, timeout, endpoint=brain.ENDPOINT):
        captured_payloads.append(payload_obj)
        return _make_fake_response()

    monkeypatch.setattr(brain, "_post_chat_completion", _fake_post)

    brain.ask_with_tools("query", tools=[], tool_handlers={})

    first_messages = captured_payloads[0]["messages"]
    system_content = first_messages[0]["content"]
    assert "MEMORIA RELEVANTE" not in system_content


def test_ask_with_tools_recall_not_injected_when_block_empty(monkeypatch):
    """ask_with_tools must leave system unchanged when recall block is ''."""
    import axi.recall as _recall
    from axi import config, brain

    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: "")

    _orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else _orig_get(key, default)
    ))

    captured_payloads: list[dict] = []

    def _fake_post(payload_obj, timeout, endpoint=brain.ENDPOINT):
        captured_payloads.append(payload_obj)
        return _make_fake_response()

    monkeypatch.setattr(brain, "_post_chat_completion", _fake_post)

    brain.ask_with_tools("query", tools=[], tool_handlers={})

    system_content = captured_payloads[0]["messages"][0]["content"]
    assert "MEMORIA RELEVANTE" not in system_content
    assert "RELEVANT MEMORY" not in system_content


# ---------------------------------------------------------------------------
# FIX 3 — 4B retry path does NOT trigger a second recall embed
# ---------------------------------------------------------------------------

def test_ask_impl_retry_does_not_double_embed(monkeypatch):
    """The 4B budget-retry path must not fire a second recall embed."""
    import axi.recall as _recall
    from axi import config, brain

    embed_calls: list[str] = []

    def _counting_recall(query, **kw):
        embed_calls.append(query)
        return "MEMORIA RELEVANTE:\n- El 11 de junio: dormí 5h"

    monkeypatch.setattr(_recall, "build_recall_block", _counting_recall)

    _orig_get = config.get
    monkeypatch.setattr(config, "get", lambda key, default=None: (
        True if key == "graph_recall" else _orig_get(key, default)
    ))

    call_count = [0]

    def _fake_post(payload_obj, timeout, endpoint=brain.ENDPOINT):
        call_count[0] += 1
        if call_count[0] == 1:
            # First call: return reasoning-consumed response to trigger retry
            return {
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": "",
                        "reasoning_content": "lots of reasoning",
                    },
                    "finish_reason": "length",
                }],
                "usage": {},
            }
        # Second call (retry): return normal response
        return _make_fake_response("final answer")

    monkeypatch.setattr(brain, "_post_chat_completion", _fake_post)
    # Stub routing so we don't need a live VT server
    monkeypatch.setattr(brain, "_route", lambda *a, **kw: "4b")
    monkeypatch.setattr(brain, "is_vt_alive", lambda *a, **kw: False)

    brain.ask("test recall retry")

    # Recall embed must fire exactly ONCE even though _post was called twice
    assert len(embed_calls) == 1
