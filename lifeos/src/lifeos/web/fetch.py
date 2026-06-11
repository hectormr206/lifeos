"""Page fetch adapter for lifeos.web.

Fetches a URL with stdlib urllib, reads at most max_bytes, runs
trafilatura.extract() for clean plain text, and truncates to MAX_PAGE_CHARS.

All failures return PageText(url, "", ok=False). Never raises.
"""
from __future__ import annotations

import logging
import urllib.error
import urllib.request
from typing import Callable

import trafilatura

from lifeos.web.port import FETCH_TIMEOUT, MAX_PAGE_BYTES, MAX_PAGE_CHARS, PageText

log = logging.getLogger("lifeos.web.fetch")


def read(
    url: str,
    *,
    urlopen: Callable = urllib.request.urlopen,
    timeout: float = FETCH_TIMEOUT,
    max_bytes: int = MAX_PAGE_BYTES,
) -> PageText:
    """Fetch ``url`` and return extracted plain text as a PageText.

    Args:
        url:       Target URL.
        urlopen:   Injectable HTTP callable (default: urllib.request.urlopen).
        timeout:   Request timeout in seconds.
        max_bytes: Maximum raw bytes to read from the response body.

    Returns:
        PageText(url, text, ok=True)  on success with non-empty extraction.
        PageText(url, "", ok=False)   on any fetch/extraction failure.
    """
    try:
        req = urllib.request.Request(url)
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read(max_bytes)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        log.debug("fetch failed for %s: %s", url, exc)
        return PageText(url=url, text="", ok=False)
    except Exception as exc:  # noqa: BLE001
        log.warning("fetch unexpected error for %s: %s", url, exc)
        return PageText(url=url, text="", ok=False)

    # Decode best-effort; errors="replace" never raises, so no try/except needed.
    # trafilatura handles encoding detection from the HTML internally.
    html = raw.decode("utf-8", errors="replace")

    extracted = trafilatura.extract(html)
    if not extracted:
        return PageText(url=url, text="", ok=False)

    text = extracted[:MAX_PAGE_CHARS]
    return PageText(url=url, text=text, ok=True)
