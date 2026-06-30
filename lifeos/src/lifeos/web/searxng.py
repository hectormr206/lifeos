"""SearXNG search adapter for lifeos.web.

Implements the WebResearchPort.search interface over a local SearXNG
instance using stdlib urllib only (zero new transport dependencies).
"""
from __future__ import annotations

import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable

from lifeos.web.port import MAX_SEARCH_BYTES, MAX_SNIPPET_CHARS, SEARCH_TIMEOUT, TOP_N, SearchResult

log = logging.getLogger("lifeos.web.searxng")


class SearXNGAdapter:
    """HTTP adapter for the local SearXNG JSON search API.

    Args:
        base_url: Base URL of the SearXNG instance, e.g. ``http://127.0.0.1:8888``.
        urlopen:  Injectable HTTP callable (default: urllib.request.urlopen).
                  Accepts a ``urllib.request.Request`` and a ``timeout`` keyword arg.
        timeout:  Request timeout in seconds (default: SEARCH_TIMEOUT from port).
    """

    def __init__(
        self,
        base_url: str,
        *,
        urlopen: Callable = urllib.request.urlopen,
        timeout: float = SEARCH_TIMEOUT,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._urlopen = urlopen
        self._timeout = timeout

    def search(
        self,
        query: str,
        *,
        limit: int = TOP_N,
        time_range: str | None = None,
        categories: str | None = None,
    ) -> list[SearchResult]:
        """Return up to ``limit`` SearchResult entries for ``query``.

        ``time_range`` (``day``/``week``/``month``/``year``) and ``categories``
        (e.g. ``news``) bias results toward fresh / topical content; both are
        forwarded to SearXNG only when provided, so callers that omit them keep
        the exact prior behavior.

        Returns an empty list on any error (URLError, timeout, bad JSON).
        Never raises.
        """
        params = [
            ("format", "json"),
            ("q", query),
        ]
        if time_range:
            params.append(("time_range", time_range))
        if categories:
            params.append(("categories", categories))
        url = f"{self._base_url}/search?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url)
        try:
            with self._urlopen(req, timeout=self._timeout) as resp:
                raw = resp.read(MAX_SEARCH_BYTES)
            data = json.loads(raw)
            if not isinstance(data, dict):
                return []
            raw_results = data.get("results", [])
            out: list[SearchResult] = []
            for item in raw_results[:limit]:
                if not isinstance(item, dict):
                    continue
                snippet = (item.get("content") or "")[:MAX_SNIPPET_CHARS]
                out.append(
                    SearchResult(
                        title=item.get("title") or "",
                        url=item.get("url") or "",
                        snippet=snippet,
                    )
                )
            return out
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
            log.debug("SearXNG search failed: %s", exc)
            return []
        except Exception as exc:  # noqa: BLE001
            log.warning("SearXNG search unexpected error: %s", exc)
            return []
