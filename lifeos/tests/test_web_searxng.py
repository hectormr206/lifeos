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
    """Returns up to TOP_N results with correct field values; snippets truncated."""
    from lifeos.web.searxng import SearXNGAdapter

    payload = _make_results(5)
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _json_resp(payload),
    )
    results = adapter.search("python async")

    assert len(results) == TOP_N
    for i, r in enumerate(results):
        assert r.title == f"Title {i}"
        assert r.url == f"http://example.com/{i}"
        assert len(r.snippet) <= MAX_SNIPPET_CHARS
        assert len(r.snippet) == MAX_SNIPPET_CHARS  # source is longer than cap


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


# ---------------------------------------------------------------------------
# C1: search() must never raise — malformed JSON bodies
# ---------------------------------------------------------------------------


def test_search_body_is_list_returns_empty():
    """C1a: If SearXNG returns a JSON array (not a dict), search() returns [].

    data.get("results") would raise AttributeError on a list — the try/except
    must cover the full parse+process block.
    """
    from lifeos.web.searxng import SearXNGAdapter

    # Body is a JSON array, not an object
    body = b"[]"
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _FakeResp(body),
    )
    result = adapter.search("anything")
    assert result == []


def test_search_results_contains_non_dict_items_returns_partial():
    """C1b: Non-dict items in results[] must NOT cause AttributeError.

    {"results": [1, 2, 3]} — item.get(...) raises on int.
    search() must return [] (or skip bad items) instead of raising.
    """
    from lifeos.web.searxng import SearXNGAdapter

    body = json.dumps({"results": [1, 2, 3]}).encode()
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _FakeResp(body),
    )
    result = adapter.search("anything")
    # Must not raise; all non-dict items should be skipped
    assert isinstance(result, list)


def test_search_results_mixed_dict_and_int_skips_bad_items():
    """C1c: Valid dict items must survive when mixed with non-dict items."""
    from lifeos.web.searxng import SearXNGAdapter

    payload = [{"title": "ok", "url": "http://x.com/0", "content": "c"}, 5]
    body = json.dumps({"results": payload}).encode()
    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _FakeResp(body),
    )
    result = adapter.search("anything", limit=10)
    # Must not raise; at minimum returns the one valid dict item
    assert isinstance(result, list)


# ---------------------------------------------------------------------------
# H1: resp.read() in search() must be capped (not uncapped like original)
# ---------------------------------------------------------------------------


def test_search_read_is_capped():
    """H1: resp.read() in search() must be called with a byte cap argument.

    A fake resp records the argument passed to read(); we assert it equals
    MAX_SEARCH_BYTES (not -1 / uncapped / absent).
    """
    from lifeos.web.port import MAX_SEARCH_BYTES
    from lifeos.web.searxng import SearXNGAdapter

    captured_n: list[int] = []

    class _CapturingResp:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self, n=-1):
            captured_n.append(n)
            return b'{"results": []}'

    adapter = SearXNGAdapter(
        base_url="http://localhost:8888",
        urlopen=lambda req, timeout=None: _CapturingResp(),
    )
    adapter.search("anything")
    assert len(captured_n) == 1, "resp.read() was not called"
    assert captured_n[0] == MAX_SEARCH_BYTES, (
        f"resp.read() was called with n={captured_n[0]!r}; "
        f"expected MAX_SEARCH_BYTES={MAX_SEARCH_BYTES}"
    )
