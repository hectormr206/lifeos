"""lifeos.web — DI module for web research.

Provides injectable callables (search_fn, read_fn, enabled_fn) and a
configure() setter that mirrors the pattern in lifeos.autonomous.cron.

The SEARXNG_URL env seam mirrors LIFEOS_STATE_DIR: read once at configure()
time (or lazily on first use), with a localhost default.

Usage (from axi dashboard lifespan):

    from lifeos.web.searxng import SearXNGAdapter
    import lifeos.web.fetch as web_fetch
    import lifeos.web as web_research

    _searxng = SearXNGAdapter(base_url=config.get("searxng_url", SEARXNG_URL))
    web_research.configure(
        search_fn=_searxng.search,
        read_fn=web_fetch.read,
        enabled_fn=lambda: bool(config.get("web_research_enabled", True)),
    )
"""
from __future__ import annotations

import os
from typing import Callable

from lifeos.web.port import PageText, SearchResult

# ---------------------------------------------------------------------------
# Env seam
# ---------------------------------------------------------------------------

SEARXNG_URL: str = os.environ.get("SEARXNG_URL", "http://127.0.0.1:8888")

# ---------------------------------------------------------------------------
# Module-level injected callables
# ---------------------------------------------------------------------------

_search_fn: Callable[[str], list[SearchResult]] | None = None
_read_fn: Callable[[str], PageText] | None = None
_enabled_fn: Callable[[], bool] | None = None


def configure(
    *,
    search_fn: Callable[[str], list[SearchResult]],
    read_fn: Callable[[str], PageText],
    enabled_fn: Callable[[], bool] | None = None,
) -> None:
    """Inject web-research callables. Calling configure() resets state."""
    global _search_fn, _read_fn, _enabled_fn
    _search_fn = search_fn
    _read_fn = read_fn
    _enabled_fn = enabled_fn


def get_search_fn() -> Callable[[str], list[SearchResult]] | None:
    """Return the currently injected search callable, or None if unconfigured."""
    return _search_fn


def get_read_fn() -> Callable[[str], PageText] | None:
    """Return the currently injected read callable, or None if unconfigured."""
    return _read_fn


def is_enabled() -> bool:
    """Return True when web research is enabled and configured."""
    if _enabled_fn is not None:
        return bool(_enabled_fn())
    return _search_fn is not None
