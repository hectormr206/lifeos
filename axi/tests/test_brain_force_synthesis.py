"""ask_with_tools final-round forced synthesis (small-model convergence).

A 4B model tends to call the tool every round and never stop to answer. When
the caller passes `final_synthesis_prompt`, the LAST round must drop the tools
and append the nudge so the model produces a final answer instead of the
"could not complete tool call" sentinel.
"""
from __future__ import annotations

import json


def _tool_call_response():
    return {
        "choices": [{
            "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [{
                    "id": "c1",
                    "type": "function",
                    "function": {"name": "web_search",
                                 "arguments": json.dumps({"query": "x"})},
                }],
            }
        }]
    }


def _final_response(text):
    return {"choices": [{"message": {"role": "assistant", "content": text}}]}


def test_final_round_forces_synthesis_without_tools(monkeypatch):
    from axi import brain
    import axi.recall as _recall

    monkeypatch.setattr(_recall, "build_recall_block", lambda *a, **kw: "")

    payloads: list[dict] = []
    # Model insists on calling the tool every tool-enabled round; the forced
    # final round (no tools) returns the digest.
    responses = [_tool_call_response(), _tool_call_response(),
                 _tool_call_response(), _final_response('{"ok": "digest"}')]

    def _fake_post(payload, timeout, endpoint=brain.ENDPOINT):
        payloads.append(payload)
        return responses[len(payloads) - 1]

    monkeypatch.setattr(brain, "_post_chat_completion", _fake_post)

    out = brain.ask_with_tools(
        "tráeme noticias",
        tools=[brain_dummy_tool()],
        tool_handlers={"web_search": lambda args: {"results": []}},
        max_tool_rounds=3,
        final_synthesis_prompt="Respondé AHORA con el JSON, no busques más.",
    )

    assert out == '{"ok": "digest"}'                 # got the answer, not the sentinel
    assert "no pudo completar" not in out.lower()
    # The final payload must NOT carry tools (forced synthesis).
    assert "tools" not in payloads[-1]
    # The synthesis nudge was appended as the last user message.
    assert payloads[-1]["messages"][-1]["role"] == "user"
    assert "no busques más" in payloads[-1]["messages"][-1]["content"].lower()
    # Earlier rounds DID offer tools.
    assert "tools" in payloads[0]


def brain_dummy_tool():
    return {
        "type": "function",
        "function": {"name": "web_search", "description": "x",
                     "parameters": {"type": "object", "properties": {}}},
    }
