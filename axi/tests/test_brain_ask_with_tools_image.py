"""Tests for ask_with_tools image_b64 support (Feature 1).

When image_b64 is provided, the user message sent to the LLM must be a
content list containing both a text part and an image_url part — same
structure as the vision path in brain.ask().

When image_b64 is None the user message is unchanged (plain string).
"""
from __future__ import annotations

import json
from unittest.mock import patch

import axi.brain as brain


class _FakeResp:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self._body


def _capture_chat_payload():
    """Return (captured_list, fake_urlopen) that records each chat-completion body."""
    captured = []

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        body = json.loads(req.data.decode())
        url = getattr(req, "full_url", "") or ""
        if "embeddings" in url or "input" in body:
            # embed pre-call — return empty so recall silently skips
            return _FakeResp(json.dumps({"data": []}).encode())
        captured.append(body)
        resp_body = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "ok"}}]
        }).encode()
        return _FakeResp(resp_body)

    return captured, fake_urlopen


class TestAskWithToolsImageB64:
    """ask_with_tools correctly injects image_b64 into the user message."""

    def test_image_b64_produces_content_list_with_text_and_image(self):
        """When image_b64 is provided, the user message is a list with text + image_url."""
        captured, fake = _capture_chat_payload()
        tools = [{"type": "function", "function": {"name": "web_search", "parameters": {}}}]
        with patch.object(brain.urllib.request, "urlopen", fake):
            brain.ask_with_tools(
                "describe what you see",
                tools=tools,
                tool_handlers={"web_search": lambda _: "result"},
                image_b64="ZmFrZWltYWdl",
            )
        assert captured, "at least one chat-completion call must be made"
        messages = captured[0]["messages"]
        user_msg = messages[-1]
        assert user_msg["role"] == "user"
        content = user_msg["content"]
        assert isinstance(content, list), "content must be a list when image_b64 is given"
        types = [part["type"] for part in content]
        assert "text" in types, "content list must include a text part"
        assert "image_url" in types, "content list must include an image_url part"

    def test_image_b64_text_part_contains_prompt(self):
        """The text part of the content list contains the original prompt."""
        captured, fake = _capture_chat_payload()
        tools = [{"type": "function", "function": {"name": "web_search", "parameters": {}}}]
        with patch.object(brain.urllib.request, "urlopen", fake):
            brain.ask_with_tools(
                "what is on screen",
                tools=tools,
                tool_handlers={"web_search": lambda _: "result"},
                image_b64="ZmFrZWltYWdl",
            )
        messages = captured[0]["messages"]
        user_msg = messages[-1]
        text_parts = [p for p in user_msg["content"] if p["type"] == "text"]
        assert text_parts, "must have a text part"
        assert "what is on screen" in text_parts[0]["text"]

    def test_image_b64_image_url_contains_base64(self):
        """The image_url part encodes the image as a data URI."""
        captured, fake = _capture_chat_payload()
        tools = [{"type": "function", "function": {"name": "web_search", "parameters": {}}}]
        with patch.object(brain.urllib.request, "urlopen", fake):
            brain.ask_with_tools(
                "look at this",
                tools=tools,
                tool_handlers={"web_search": lambda _: "result"},
                image_b64="TESTB64DATA",
            )
        messages = captured[0]["messages"]
        user_msg = messages[-1]
        img_parts = [p for p in user_msg["content"] if p["type"] == "image_url"]
        assert img_parts, "must have an image_url part"
        url = img_parts[0]["image_url"]["url"]
        assert "TESTB64DATA" in url
        assert url.startswith("data:image/")

    def test_no_image_b64_produces_plain_string_user_message(self):
        """When image_b64 is None, the user message is a plain string (unchanged behavior)."""
        captured, fake = _capture_chat_payload()
        tools = [{"type": "function", "function": {"name": "web_search", "parameters": {}}}]
        with patch.object(brain.urllib.request, "urlopen", fake):
            brain.ask_with_tools(
                "plain question",
                tools=tools,
                tool_handlers={"web_search": lambda _: "result"},
                image_b64=None,
            )
        messages = captured[0]["messages"]
        user_msg = messages[-1]
        assert isinstance(user_msg["content"], str), (
            "content must be a plain string when image_b64 is None"
        )
        assert user_msg["content"] == "plain question"
