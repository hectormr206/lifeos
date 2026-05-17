"""Tests for the brain HTTP client — payload shape and response parsing.

Network is fully mocked. We only assert the things we control: that we
build OpenAI-compatible messages, include temporal context, attach
images correctly, and parse the assistant's content out.
"""
from __future__ import annotations

import io
import json
from unittest.mock import patch

from axi import brain


def _mock_response(content: str) -> object:
    body = {
        "choices": [
            {"message": {"role": "assistant", "content": content, "reasoning_content": None}}
        ]
    }
    return io.BytesIO(json.dumps(body).encode("utf-8"))


class _FakeResp:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self._body


def _capture_payload():
    captured = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data.decode())
        body = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "ok"}}]
        }).encode()
        return _FakeResp(body)

    return captured, fake_urlopen


def test_ask_includes_temporal_context_in_system():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        out = brain.ask("hola")
    assert out == "ok"
    msgs = captured["body"]["messages"]
    sys_msg = msgs[0]["content"]
    assert "CONTEXTO TEMPORAL" in sys_msg


def test_ask_appends_history_in_order():
    captured, fake = _capture_payload()
    history = [
        {"role": "user", "content": "anterior pregunta"},
        {"role": "assistant", "content": "anterior respuesta"},
    ]
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("ahora", history=history)
    msgs = captured["body"]["messages"]
    # system, prev_user, prev_assistant, current_user
    assert len(msgs) == 4
    assert msgs[1]["content"] == "anterior pregunta"
    assert msgs[2]["content"] == "anterior respuesta"
    assert msgs[3]["content"] == "ahora"


def test_ask_attaches_image_when_provided():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("describe", image_b64="ZmFrZQ==")
    msgs = captured["body"]["messages"]
    user_content = msgs[-1]["content"]
    assert isinstance(user_content, list)
    types = [c["type"] for c in user_content]
    assert "image_url" in types
    assert "text" in types


def test_ask_disables_thinking_by_default():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("hola")
    assert captured["body"]["chat_template_kwargs"]["enable_thinking"] is False
