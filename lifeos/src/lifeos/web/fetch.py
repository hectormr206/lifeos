"""Page fetch adapter for lifeos.web.

Fetches a URL with stdlib urllib, reads at most max_bytes, runs
trafilatura.extract() for clean plain text, and truncates to MAX_PAGE_CHARS.

All failures return PageText(url, "", ok=False). Never raises.
"""
from __future__ import annotations

import logging
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from typing import Callable

import trafilatura

from lifeos.web.port import FETCH_TIMEOUT, MAX_PAGE_BYTES, MAX_PAGE_CHARS, PageText

log = logging.getLogger("lifeos.web.fetch")

# Cap on extracted links so a huge page can't bloat the tool result / prompt.
_MAX_LINKS = 40


class _AnchorCollector(HTMLParser):
    """Collect (anchor_text, href) pairs from <a> tags."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self._href = href
                self._buf = []

    def handle_data(self, data):
        if self._href is not None:
            self._buf.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            text = " ".join("".join(self._buf).split())
            self.links.append((text, self._href))
            self._href = None
            self._buf = []


def _extract_links(html: str, base_url: str) -> tuple[dict, ...]:
    """Real hyperlinks from the page, resolved to absolute http(s) URLs.

    Skips empty/anchor-only/non-http links, deduplicates by URL, and caps the
    count. This is what lets a model cite REAL source URLs for a link
    aggregator (e.g. Hacker News) instead of fabricating them — trafilatura's
    text extraction drops links entirely.
    """
    try:
        parser = _AnchorCollector()
        parser.feed(html)
    except Exception:  # noqa: BLE001 — never let parsing break a fetch
        return ()
    out: list[dict] = []
    seen: set[str] = set()
    for text, href in parser.links:
        if not href or href.startswith(("#", "javascript:", "mailto:")):
            continue
        absolute = urllib.parse.urljoin(base_url, href)
        if not absolute.startswith(("http://", "https://")):
            continue
        if absolute in seen:
            continue
        seen.add(absolute)
        out.append({"text": text[:200], "url": absolute})
        if len(out) >= _MAX_LINKS:
            break
    return tuple(out)

# A realistic desktop User-Agent. Many sites (Wikipedia, python.org, news
# outlets) serve a block/consent page or 403 to the default "Python-urllib/x.y"
# agent, which leaves trafilatura nothing to extract. A standard browser UA
# gets the real article HTML.
_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)


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
        req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
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
    # Trafilatura gives clean prose but drops links; extract the real anchors
    # separately so callers (e.g. the briefing) can cite genuine source URLs.
    links = _extract_links(html, url)
    return PageText(url=url, text=text, ok=True, links=links)
