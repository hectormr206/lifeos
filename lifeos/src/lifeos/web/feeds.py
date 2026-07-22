"""RSS/Atom feed adapter for lifeos.web.

Fetches a feed URL with stdlib urllib (browser User-Agent), parses it with
``xml.etree.ElementTree`` and returns dated ``FeedEntry`` records. Handles BOTH
RSS (``channel/item``) and Atom (``feed/entry``) shapes, and both common date
formats (RFC-822 ``pubDate`` and ISO-8601 ``published``/``updated``).

This exists because ``lifeos.web.fetch.read`` runs trafilatura, which returns
EMPTY for XML feeds — feeds must be parsed as raw bytes, not article text. No
third-party dependency is used (``feedparser``/``httpx`` are NOT installed):
only the stdlib.

Never raises: any fetch/parse error yields ``[]`` (or ``None`` for a date).
The HTTP getter is injectable (``http_get``) so tests never touch the network.
"""
from __future__ import annotations

import logging
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Callable

log = logging.getLogger("lifeos.web.feeds")

# A realistic desktop User-Agent — same rationale as lifeos.web.fetch: many
# sites 403/redirect the default "Python-urllib" agent. Kept in sync with
# fetch._USER_AGENT (imported so there is a single source of truth).
try:  # pragma: no cover - trivial import guard
    from lifeos.web.fetch import _USER_AGENT
except Exception:  # noqa: BLE001 — never let an import break feed parsing
    _USER_AGENT = (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    )

# Bound the raw bytes read from a feed and how long we wait, so a huge or slow
# feed can neither bloat memory nor hang the briefing pipeline.
_MAX_FEED_BYTES = 2_000_000
_FEED_TIMEOUT = 10.0
# Cap on stored summary length so a verbose feed can't bloat the prompt/card.
_MAX_SUMMARY = 500

HttpGet = Callable[[str], bytes]  # (url) -> raw response bytes


@dataclass
class FeedEntry:
    """One item/entry parsed from an RSS or Atom feed.

    ``published`` is a timezone-aware UTC datetime, or ``None`` when the entry
    carried no parseable date (which the freshness filter treats as NOT fresh).
    """

    title: str
    url: str
    published: datetime | None
    summary: str = ""


def _default_http_get(url: str) -> bytes:
    """Fetch raw feed bytes with a browser UA. Raises on any HTTP/network error."""
    req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(req, timeout=_FEED_TIMEOUT) as resp:
        return resp.read(_MAX_FEED_BYTES)


def parse_feed_date(s: str | None) -> datetime | None:
    """Parse a feed date string to a tz-aware UTC datetime, or None.

    Tries RFC-822 (``Wed, 22 Jul 2026 11:47:59 GMT`` — RSS ``pubDate``) first,
    then ISO-8601 (``2026-07-22T11:47:59Z`` / ``...+00:00`` — Atom
    ``published``/``updated``). A trailing ``Z`` is normalized to ``+00:00``
    for ``datetime.fromisoformat``. A naive result is assumed UTC.
    """
    if not s:
        return None
    raw = s.strip()
    if not raw:
        return None
    # RFC-822 (RSS pubDate / dc:date sometimes).
    try:
        dt = parsedate_to_datetime(raw)
        if dt is not None:
            return _to_utc(dt)
    except (TypeError, ValueError, IndexError):
        pass
    # ISO-8601 (Atom published/updated). Normalize a trailing Z.
    iso = raw
    if iso.endswith("Z"):
        iso = iso[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(iso)
        return _to_utc(dt)
    except ValueError:
        return None


def _to_utc(dt: datetime) -> datetime:
    """Return `dt` as tz-aware UTC (naive input is assumed to already be UTC)."""
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _localname(tag: str) -> str:
    """Strip an XML namespace: ``{http://...}title`` -> ``title``."""
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _entry_text(el: ET.Element) -> str:
    """All text under an element, flattened and whitespace-collapsed."""
    return " ".join("".join(el.itertext()).split())


def _entry_from_element(el: ET.Element) -> FeedEntry:
    """Build a FeedEntry from one ``<item>`` (RSS) or ``<entry>`` (Atom)."""
    title = ""
    summary = ""
    rss_link = ""          # RSS: text of <link>
    atom_alt = ""          # Atom: href of rel="alternate"
    atom_any = ""          # Atom: href of the first <link>
    date_published = ""    # pubDate / published
    date_updated = ""      # updated (fallback when no published)

    for child in el:
        name = _localname(child.tag).lower()
        if name == "title" and not title:
            title = _entry_text(child)
        elif name == "link":
            href = child.get("href")
            if href:  # Atom-style link element
                rel = (child.get("rel") or "alternate").lower()
                if rel == "alternate" and not atom_alt:
                    atom_alt = href.strip()
                if not atom_any:
                    atom_any = href.strip()
            else:  # RSS-style: URL is the element text
                text = (child.text or "").strip()
                if text and not rss_link:
                    rss_link = text
        elif name in ("pubdate", "published") and not date_published:
            date_published = (child.text or "").strip()
        elif name == "date" and not date_published:  # dc:date
            date_published = (child.text or "").strip()
        elif name == "updated" and not date_updated:
            date_updated = (child.text or "").strip()
        elif name in ("description", "summary") and not summary:
            summary = _entry_text(child)
        elif name == "content" and not summary:
            summary = _entry_text(child)

    url = rss_link or atom_alt or atom_any
    published = parse_feed_date(date_published or date_updated)
    return FeedEntry(
        title=title,
        url=url,
        published=published,
        summary=summary[:_MAX_SUMMARY],
    )


def fetch_feed(
    url: str,
    *,
    limit: int = 20,
    http_get: HttpGet | None = None,
) -> list[FeedEntry]:
    """Fetch and parse an RSS/Atom feed into dated ``FeedEntry`` records.

    Args:
        url:      Feed URL (RSS or Atom).
        limit:    Max entries to return (in document order — feeds are newest-first).
        http_get: Injectable ``(url) -> bytes`` transport (default: urllib GET
                  with a browser UA). Tests pass a fake here — no network.

    Returns:
        A list of ``FeedEntry`` (possibly empty). Never raises: any
        fetch/decode/parse error yields ``[]``.
    """
    getter = http_get or _default_http_get
    try:
        body = getter(url)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        log.debug("feed fetch failed for %s: %s", url, exc)
        return []
    except Exception as exc:  # noqa: BLE001
        log.warning("feed fetch unexpected error for %s: %s", url, exc)
        return []
    if not body:
        return []
    try:
        root = ET.fromstring(body)
    except Exception as exc:  # noqa: BLE001 — malformed XML must not raise
        log.debug("feed parse failed for %s: %s", url, exc)
        return []

    entries: list[FeedEntry] = []
    for el in root.iter():
        if _localname(el.tag).lower() in ("item", "entry"):
            entries.append(_entry_from_element(el))
            if len(entries) >= limit:
                break
    return entries
