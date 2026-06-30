"""Tests for lifeos.web.fetch — read().

Uses an injected fake urlopen and monkeypatched trafilatura.extract.
Zero network calls.
"""
from __future__ import annotations

import urllib.error

import pytest

from lifeos.web.port import MAX_PAGE_BYTES, MAX_PAGE_CHARS


# ---------------------------------------------------------------------------
# Fake HTTP transport
# ---------------------------------------------------------------------------


class _FakeResp:
    """Context-manager HTTP response with a size-capped read()."""

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


FAKE_HTML = b"<html><body><p>Hello world content.</p></body></html>"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_read_success_and_truncation(monkeypatch):
    """Returns PageText(ok=True) with text truncated to MAX_PAGE_CHARS."""
    import lifeos.web.fetch as fetch_mod
    import trafilatura  # must be importable for patching

    long_text = "A" * (MAX_PAGE_CHARS + 500)
    monkeypatch.setattr(trafilatura, "extract", lambda html, **kw: long_text)  # noqa: ARG005

    def fake_urlopen(req, timeout=None):
        return _FakeResp(FAKE_HTML)

    result = fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    assert result.ok is True
    assert result.url == "http://example.com"
    assert len(result.text) == MAX_PAGE_CHARS


def test_read_fetch_failure(monkeypatch):
    """Returns PageText(ok=False, text='') when the fetch raises URLError."""
    import lifeos.web.fetch as fetch_mod

    def fake_urlopen(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    result = fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    assert result.ok is False
    assert result.text == ""
    assert result.url == "http://example.com"


def test_read_non_html_empty_extraction(monkeypatch):
    """Returns PageText(ok=False, text='') when trafilatura returns None."""
    import lifeos.web.fetch as fetch_mod
    import trafilatura

    monkeypatch.setattr(trafilatura, "extract", lambda html, **kw: None)  # noqa: ARG005

    def fake_urlopen(req, timeout=None):
        return _FakeResp(FAKE_HTML)

    result = fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    assert result.ok is False
    assert result.text == ""


def test_read_sends_browser_user_agent(monkeypatch):
    """read() must send a real browser User-Agent.

    Many sites (Wikipedia, python.org, news outlets) serve a block/consent
    page or 403 to the default ``Python-urllib/x.y`` agent, leaving
    trafilatura nothing to extract. Caught only by real end-to-end fetching;
    the mocked transport never exercised request headers before.
    """
    import lifeos.web.fetch as fetch_mod
    import trafilatura

    monkeypatch.setattr(trafilatura, "extract", lambda html, **kw: "text")  # noqa: ARG005

    captured: dict[str, str | None] = {}

    def fake_urlopen(req, timeout=None):
        captured["ua"] = req.get_header("User-agent")
        return _FakeResp(FAKE_HTML)

    fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    ua = captured["ua"]
    assert ua, "read() sent no User-Agent header"
    assert "python-urllib" not in ua.lower(), "must not use the default urllib UA"


def test_read_size_cap(monkeypatch):
    """H2: resp.read() must be called with max_bytes as its argument (bounded call).

    Captures the exact `n` passed to resp.read() and asserts it equals
    MAX_PAGE_BYTES — not uncapped (n=-1), not too small (e.g. 1), not too
    large.  A 1-byte cap or argless read() would both fail this test.
    """
    import lifeos.web.fetch as fetch_mod
    import trafilatura

    monkeypatch.setattr(trafilatura, "extract", lambda html, **kw: "some text")  # noqa: ARG005

    captured_n: list[int] = []

    class _CapturingResp:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self, n=-1):
            captured_n.append(n)
            return b"<html><body><p>hello</p></body></html>"

    def fake_urlopen(req, timeout=None):
        return _CapturingResp()

    result = fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    assert len(captured_n) == 1, "resp.read() was not called"
    assert captured_n[0] == MAX_PAGE_BYTES, (
        f"resp.read() called with n={captured_n[0]!r}; expected MAX_PAGE_BYTES={MAX_PAGE_BYTES}"
    )
    assert result.url == "http://example.com"


# ---------------------------------------------------------------------------
# Link extraction (real anchors — what lets a model cite genuine URLs)
# ---------------------------------------------------------------------------

_HN_LIKE = (
    b'<html><body>'
    b'<a href="https://quesma.com/blog/qwen">Qwen 3.6 is the sweet spot</a>'
    b'<a href="item?id=123">42 comments</a>'                 # relative -> resolved
    b'<a href="#top">top</a>'                                 # fragment -> skipped
    b'<a href="javascript:void(0)">x</a>'                     # js -> skipped
    b'<a href="https://quesma.com/blog/qwen">dup</a>'         # dup url -> skipped
    b'</body></html>'
)


def test_read_extracts_real_links(monkeypatch):
    import lifeos.web.fetch as fetch_mod
    import trafilatura
    monkeypatch.setattr(trafilatura, "extract", lambda html, **kw: "some text")  # noqa: ARG005

    result = fetch_mod.read(
        "https://news.ycombinator.com/",
        urlopen=lambda req, timeout=None: _FakeResp(_HN_LIKE),
    )

    urls = [l["url"] for l in result.links]
    # Absolute kept, relative resolved against base, fragment/js/dup dropped.
    assert "https://quesma.com/blog/qwen" in urls
    assert "https://news.ycombinator.com/item?id=123" in urls
    assert all(not u.startswith("#") and "javascript:" not in u for u in urls)
    assert len(urls) == len(set(urls))  # deduped
    # Anchor text is carried so the model can match title -> url.
    first = next(l for l in result.links if l["url"].endswith("/blog/qwen"))
    assert "Qwen" in first["text"]


def test_links_empty_on_fetch_failure(monkeypatch):
    import lifeos.web.fetch as fetch_mod
    import urllib.error
    def boom(req, timeout=None):
        raise urllib.error.URLError("down")
    result = fetch_mod.read("http://example.com", urlopen=boom)
    assert result.links == ()
