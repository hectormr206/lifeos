"""Tests for lifeos.web.port — constants, dataclasses, and Protocol.

TDD Phase 1.1 RED: asserts the public surface of the web port module.
"""
from __future__ import annotations

import dataclasses

import pytest


def test_constants_values():
    from lifeos.web.port import (
        TOP_N,
        MAX_SNIPPET_CHARS,
        MAX_PAGE_CHARS,
        MAX_PAGE_BYTES,
        SEARCH_TIMEOUT,
        FETCH_TIMEOUT,
    )
    assert TOP_N == 3
    assert MAX_SNIPPET_CHARS == 300
    assert MAX_PAGE_CHARS == 3000
    assert MAX_PAGE_BYTES == 2_000_000
    assert SEARCH_TIMEOUT == 5.0
    assert FETCH_TIMEOUT == 8.0


def test_search_result_is_frozen_dataclass():
    from lifeos.web.port import SearchResult

    fields = {f.name for f in dataclasses.fields(SearchResult)}
    assert fields == {"title", "url", "snippet"}

    r = SearchResult(title="T", url="http://x.com", snippet="S")
    assert r.title == "T"
    assert r.url == "http://x.com"
    assert r.snippet == "S"

    # frozen: mutation must raise
    with pytest.raises((dataclasses.FrozenInstanceError, AttributeError)):
        r.title = "changed"  # type: ignore[misc]


def test_page_text_is_frozen_dataclass():
    from lifeos.web.port import PageText

    fields = {f.name for f in dataclasses.fields(PageText)}
    assert fields == {"url", "text", "ok", "links"}

    p = PageText(url="http://x.com", text="hello", ok=True)
    assert p.ok is True
    assert p.links == ()  # defaulted so existing callers/fakes keep working

    with pytest.raises((dataclasses.FrozenInstanceError, AttributeError)):
        p.ok = False  # type: ignore[misc]


def test_web_research_port_protocol_structure():
    """WebResearchPort must be a Protocol with search and read methods."""
    from lifeos.web.port import WebResearchPort
    import typing

    # Must be a runtime-checkable Protocol or at minimum a Protocol class
    # We check it has search and read as annotations / methods.
    assert hasattr(WebResearchPort, "search")
    assert hasattr(WebResearchPort, "read")


def test_callable_type_aliases_exist():
    """SearchFn and ReadFn must be importable."""
    from lifeos.web.port import SearchFn, ReadFn  # noqa: F401
