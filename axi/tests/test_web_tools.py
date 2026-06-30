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

    def test_handler_passes_time_range_and_categories_through(self):
        """time_range/categories from tool args reach the search fn (FIX 4)."""
        captured: dict = {}
        hit = types.SimpleNamespace(title="t", url="https://e.example", snippet="s")

        fake = types.ModuleType("lifeos.web")
        fake.is_enabled = lambda: True

        def _search_fn(q, **kw):
            captured["q"] = q
            captured["kw"] = kw
            return [hit]  # non-empty → no widening retry

        fake.get_search_fn = lambda: _search_fn
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake, fake_port)
        try:
            web_search_handler({"query": "q", "time_range": "day", "categories": "news"})
        finally:
            self._restore(orig_web, orig_port)

        assert captured["q"] == "q"
        assert captured["kw"].get("time_range") == "day"
        assert captured["kw"].get("categories") == "news"

    def test_handler_widens_when_time_range_returns_empty(self):
        """If a time_range search returns 0 results, retry once WITHOUT
        time_range (the local index returns nothing for 'day'). categories is
        preserved so the freshness bias survives."""
        calls: list[dict] = []
        hit = types.SimpleNamespace(title="t", url="https://e.example", snippet="s")

        fake = types.ModuleType("lifeos.web")
        fake.is_enabled = lambda: True

        def _search_fn(q, **kw):
            calls.append(dict(kw))
            # First call (with time_range) returns nothing; retry returns a hit.
            return [] if "time_range" in kw else [hit]

        fake.get_search_fn = lambda: _search_fn
        fake_port = self._make_fake_port()
        orig_web, orig_port = self._inject(fake, fake_port)
        try:
            out = web_search_handler(
                {"query": "q", "time_range": "day", "categories": "news"}
            )
        finally:
            self._restore(orig_web, orig_port)

        assert len(calls) == 2
        assert "time_range" in calls[0]
        assert "time_range" not in calls[1]
        assert calls[1].get("categories") == "news"  # bias preserved on retry
        assert out["ok"] is True and len(out["results"]) == 1

    def test_tool_def_exposes_time_range(self):
        result = web_search_tool_def()
        props = result["function"]["parameters"]["properties"]
        assert "time_range" in props
        assert set(props["time_range"]["enum"]) == {"day", "week", "month", "year"}
        # time_range stays optional (query remains the only required field).
        assert result["function"]["parameters"]["required"] == ["query"]

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


class TestWebFetchTool:
    """web_fetch reads ONE specific URL via the injected read_fn."""

    def _inject(self, fake_web, fake_port):
        orig_web = sys.modules.get("lifeos.web")
        orig_port = sys.modules.get("lifeos.web.port")
        sys.modules["lifeos.web"] = fake_web
        sys.modules["lifeos.web.port"] = fake_port
        return orig_web, orig_port

    def _restore(self, orig_web, orig_port):
        for name, orig in (("lifeos.web", orig_web), ("lifeos.web.port", orig_port)):
            if orig is not None:
                sys.modules[name] = orig
            else:
                sys.modules.pop(name, None)

    def _fakes(self, *, enabled=True, page=None):
        web = types.ModuleType("lifeos.web")
        web.is_enabled = lambda: enabled
        if page is None:
            page = types.SimpleNamespace(url="https://news.ycombinator.com/",
                                         text="Show HN: cool thing", ok=True)
        web.get_read_fn = lambda: (lambda url: page)
        port = types.ModuleType("lifeos.web.port")
        port.MAX_PAGE_CHARS = 3000
        return web, port

    def test_tool_def_requires_url(self):
        from axi.web_tools import web_fetch_tool_def
        d = web_fetch_tool_def()
        assert d["function"]["name"] == "web_fetch"
        assert d["function"]["parameters"]["required"] == ["url"]

    def test_reads_url_text(self):
        from axi.web_tools import web_fetch_handler
        web, port = self._fakes()
        orig = self._inject(web, port)
        try:
            out = web_fetch_handler({"url": "https://news.ycombinator.com/"})
        finally:
            self._restore(*orig)
        assert out["ok"] is True
        assert "Show HN" in out["text"]

    def test_rejects_non_http_url(self):
        from axi.web_tools import web_fetch_handler
        web, port = self._fakes()
        orig = self._inject(web, port)
        try:
            out = web_fetch_handler({"url": "javascript:alert(1)"})
        finally:
            self._restore(*orig)
        assert out["ok"] is False
        assert "http" in out["error"]

    def test_disabled_returns_error(self):
        from axi.web_tools import web_fetch_handler
        web, port = self._fakes(enabled=False)
        orig = self._inject(web, port)
        try:
            out = web_fetch_handler({"url": "https://example.com"})
        finally:
            self._restore(*orig)
        assert out["ok"] is False
        assert "disabled" in out["error"]

    def test_passes_through_real_links(self):
        from axi.web_tools import web_fetch_handler
        page = types.SimpleNamespace(
            url="https://news.ycombinator.com/", text="front page", ok=True,
            links=({"text": "Qwen 3.6", "url": "https://quesma.com/blog/qwen"},),
        )
        web, port = self._fakes(page=page)
        orig = self._inject(web, port)
        try:
            out = web_fetch_handler({"url": "https://news.ycombinator.com/"})
        finally:
            self._restore(*orig)
        assert out["ok"] is True
        assert out["links"] == [{"text": "Qwen 3.6", "url": "https://quesma.com/blog/qwen"}]
