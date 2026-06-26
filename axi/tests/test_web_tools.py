"""Tests for the axi.web_tools shared module (Feature 2).

Verifies:
- web_search_tool_def() returns a well-formed OpenAI-compatible tool schema.
- web_search_handler() returns a non-empty string/dict result (HTTP mocked).
"""
from __future__ import annotations

import sys
import types
from unittest.mock import MagicMock

import pytest

from axi.web_tools import web_search_tool_def, web_search_handler


class TestWebSearchToolDef:
    """web_search_tool_def() returns the correct OpenAI-compatible schema."""

    def test_returns_dict(self):
        result = web_search_tool_def()
        assert isinstance(result, dict)

    def test_type_is_function(self):
        result = web_search_tool_def()
        assert result["type"] == "function"

    def test_function_name_is_web_search(self):
        result = web_search_tool_def()
        assert result["function"]["name"] == "web_search"

    def test_has_query_parameter(self):
        result = web_search_tool_def()
        params = result["function"]["parameters"]
        assert "query" in params["properties"]
        assert "query" in params["required"]

    def test_each_call_returns_equal_schema(self):
        """Two calls return equal (but independent) dicts."""
        a = web_search_tool_def()
        b = web_search_tool_def()
        assert a == b
        assert a is not b


class TestWebSearchHandler:
    """web_search_handler() returns a result dict; HTTP is mocked."""

    def _make_fake_lifeos_web(self, *, enabled: bool = True, results=None):
        """Build a fake lifeos.web module for sys.modules injection."""
        fake = types.ModuleType("lifeos.web")
        fake.is_enabled = lambda: enabled

        if results is None:
            r = MagicMock()
            r.title = "Test Title"
            r.url = "https://example.com"
            r.snippet = "A test snippet."
            results = [r]

        fake.get_search_fn = lambda: (lambda q: results)  # noqa: ARG005
        return fake

    def _make_fake_port(self):
        fake = types.ModuleType("lifeos.web.port")
        fake.TOP_N = 5
        fake.MAX_SNIPPET_CHARS = 200
        return fake

    def _inject(self, fake_web, fake_port):
        """Inject fake modules; return originals for teardown."""
        orig_web = sys.modules.get("lifeos.web")
        orig_port = sys.modules.get("lifeos.web.port")
        sys.modules["lifeos.web"] = fake_web
        sys.modules["lifeos.web.port"] = fake_port
        return orig_web, orig_port

    def _restore(self, orig_web, orig_port):
        if orig_web is not None:
            sys.modules["lifeos.web"] = orig_web
        else:
            sys.modules.pop("lifeos.web", None)
        if orig_port is not None:
            sys.modules["lifeos.web.port"] = orig_port
        else:
            sys.modules.pop("lifeos.web.port", None)

    def test_returns_ok_true_with_results(self):
        fake_web = self._make_fake_lifeos_web(enabled=True)
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake_web, fake_port)
        try:
            result = web_search_handler({"query": "test query"})
        finally:
            self._restore(orig_web, orig_port)

        assert isinstance(result, dict)
        assert result["ok"] is True
        assert len(result["results"]) > 0

    def test_returns_non_empty_results(self):
        fake_web = self._make_fake_lifeos_web(enabled=True)
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake_web, fake_port)
        try:
            result = web_search_handler({"query": "test"})
        finally:
            self._restore(orig_web, orig_port)

        assert result["results"], "results list must be non-empty"
        item = result["results"][0]
        assert "title" in item
        assert "url" in item
        assert "snippet" in item

    def test_empty_query_returns_error(self):
        fake_web = self._make_fake_lifeos_web()
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake_web, fake_port)
        try:
            result = web_search_handler({"query": ""})
        finally:
            self._restore(orig_web, orig_port)

        assert result["ok"] is False
        assert "error" in result

    def test_web_disabled_returns_error(self):
        fake_web = self._make_fake_lifeos_web(enabled=False)
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake_web, fake_port)
        try:
            result = web_search_handler({"query": "something"})
        finally:
            self._restore(orig_web, orig_port)

        assert result["ok"] is False
        assert "disabled" in result["error"]
