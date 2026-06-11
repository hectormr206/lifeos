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


def test_read_size_cap(monkeypatch):
    """Reads at most max_bytes bytes, even when the response is larger."""
    import lifeos.web.fetch as fetch_mod
    import trafilatura

    captured_html: list[str] = []

    def capture_extract(html, **kw):  # noqa: ARG001
        captured_html.append(html)
        return "some text"

    monkeypatch.setattr(trafilatura, "extract", capture_extract)

    large_body = b"X" * (MAX_PAGE_BYTES + 1_000_000)

    def fake_urlopen(req, timeout=None):
        return _FakeResp(large_body)

    result = fetch_mod.read("http://example.com", urlopen=fake_urlopen)

    # Must not crash; bytes passed to extract must be <= max_bytes
    assert len(captured_html) == 1
    html_bytes = captured_html[0].encode("latin-1", errors="replace")
    assert len(html_bytes) <= MAX_PAGE_BYTES
    # Result ok can be True or False depending on extraction; what matters is no crash.
    assert result.url == "http://example.com"
