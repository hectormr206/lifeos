"""Web research port — pure types, Protocol, and budgeting constants.

Zero network dependencies. This module is the hexagonal boundary for
all web-research capabilities; adapters (searxng.py, fetch.py) implement
the Protocol via injectable callables rather than inheritance.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Protocol

# ---------------------------------------------------------------------------
# Budgeting constants
# ---------------------------------------------------------------------------

TOP_N: int = 3                  # max search results to request / process
MAX_SNIPPET_CHARS: int = 300    # max chars per snippet in the brain prompt
MAX_PAGE_CHARS: int = 3000      # max chars of extracted page text in the prompt
MAX_PAGE_BYTES: int = 2_000_000 # max raw bytes to read from a fetched page
SEARCH_TIMEOUT: float = 5.0     # SearXNG HTTP request timeout (seconds)
FETCH_TIMEOUT: float = 8.0      # page fetch HTTP request timeout (seconds)

# ---------------------------------------------------------------------------
# Value objects
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class SearchResult:
    """A single result from a SearXNG search response."""
    title: str
    url: str
    snippet: str    # sourced from results[].content in the SearXNG JSON


@dataclass(frozen=True, slots=True)
class PageText:
    """Result of fetching and extracting text from a URL."""
    url: str
    text: str       # extracted plain text, truncated to MAX_PAGE_CHARS
    ok: bool        # False when fetch or extraction failed


# ---------------------------------------------------------------------------
# Port Protocol
# ---------------------------------------------------------------------------


class WebResearchPort(Protocol):
    """Hexagonal port for web research.

    Concrete adapters (SearXNGAdapter, fetch.read) satisfy this Protocol
    structurally — no inheritance needed. The dashboard injects callables
    via web_research.configure().
    """

    def search(self, query: str, *, limit: int = TOP_N) -> list[SearchResult]:
        """Return up to `limit` results for `query`, or [] on any failure."""
        ...

    def read(self, url: str) -> PageText:
        """Fetch `url` and return extracted plain text. Never raises."""
        ...


# ---------------------------------------------------------------------------
# Callable type aliases (for DI module type hints)
# ---------------------------------------------------------------------------

SearchFn = Callable[[str], list[SearchResult]]  # (query) -> results
ReadFn = Callable[[str], PageText]              # (url) -> page
