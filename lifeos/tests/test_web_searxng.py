"""Tests for lifeos.web.searxng — SearXNGAdapter.

Uses an injected fake urlopen (mirrors test_brain._FakeResp).
Zero network calls.
"""
from __future__ import annotations

import json
import urllib.error

from lifeos.web.port import MAX_SNIPPET_CHARS, TOP_N


# ---------------------------------------------------------------------------
# Fake HTTP transport helpers
# ---------------------------------------------------------------------------


class _FakeResp:
    """Minimal context-manager response mirroring test_brain._FakeResp."""

    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, n: int = -1) -> bytes:
        if n < 0:
            return self._body
        return self._body[:n]


def _make_results(n: int) -> list[dict]:
    return [
        {"title": f"Title {i}", "url": f"http://example.com/{i}", "content": f"Snippet {i} " + "x" * 400}
        for i in range(n)
    ]


def _json_resp(results: list[dict]) -> _FakeResp:
    body = json.dumps({"results": results}).encode("utf-8")
    return _FakeResp(body)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_search_success_parse():
    """Returns up to TOP_N results with correct fields; snippets truncated."""
    from lifeos.web.searxng import SearXNGAdapter

    payload = _make_results(5)
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _json_resp(payload),
    )
    results = adapter.search("python async")

    assert len(results) == TOP_N
    for r in results:
        assert hasattr(r, "title")
        assert hasattr(r, "url")
        assert hasattr(r, "snippet")
        assert len(r.snippet) <= MAX_SNIPPET_CHARS


def test_search_zero_results():
    """Returns [] when SearXNG has no results."""
    from lifeos.web.searxng import SearXNGAdapter

    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _json_resp([]),
    )
    assert adapter.search("noresults") == []


def test_search_unreachable_returns_empty():
    """Returns [] and does NOT raise when SearXNG is unreachable."""
    from lifeos.web.searxng import SearXNGAdapter

    def _raise(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    adapter = SearXNGAdapter(base_url="http://localhost:8888", urlopen=_raise)
    result = adapter.search("something")
    assert result == []


def test_search_limit_cap():
    """Respects explicit limit parameter."""
    from lifeos.web.searxng import SearXNGAdapter

    payload = _make_results(10)
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _json_resp(payload),
    )
    results = adapter.search("python", limit=2)
    assert len(results) == 2


def test_search_snippet_truncation():
    """Snippet is truncated to MAX_SNIPPET_CHARS even when source is longer."""
    from lifeos.web.searxng import SearXNGAdapter

    long_content = "A" * (MAX_SNIPPET_CHARS + 100)
    payload = [{"title": "T", "url": "http://x.com", "content": long_content}]
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _json_resp(payload),
    )
    results = adapter.search("test", limit=1)
    assert len(results) == 1
    assert len(results[0].snippet) == MAX_SNIPPET_CHARS
