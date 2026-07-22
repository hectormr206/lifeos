"""Tests for lifeos.web.feeds — RSS/Atom parsing + date handling (TDD).

Zero network: an injected fake ``http_get`` returns fixture feed bytes. Covers
RSS + Atom shapes, RFC-822 + ISO-8601 dates, missing dates, and defensive
failure (bad transport / malformed XML -> []).
"""
from __future__ import annotations

from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

RSS_FEED = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Muy Linux</title>
    <link>https://www.muylinux.com/</link>
    <item>
      <title>Kernel 6.20 released today</title>
      <link>https://www.muylinux.com/kernel-620</link>
      <pubDate>Wed, 22 Jul 2026 09:30:00 +0000</pubDate>
      <description>El nuevo kernel trae mejoras de rendimiento.</description>
    </item>
    <item>
      <title>Old news without a date</title>
      <link>https://www.muylinux.com/undated</link>
      <description>Sin fecha.</description>
    </item>
  </channel>
</rss>"""

ATOM_FEED = b"""<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Simon Willison</title>
  <entry>
    <title>A new LLM benchmark</title>
    <link rel="edit" href="https://simonwillison.net/edit/1"/>
    <link rel="alternate" href="https://simonwillison.net/2026/Jul/22/llm-bench/"/>
    <published>2026-07-22T14:05:00Z</published>
    <summary>Notes on the benchmark.</summary>
  </entry>
  <entry>
    <title>Only-updated entry</title>
    <link rel="alternate" href="https://simonwillison.net/2026/Jul/21/x/"/>
    <updated>2026-07-21T08:00:00+00:00</updated>
    <content>Body text here.</content>
  </entry>
</feed>"""


def _fake_get(mapping):
    """(url)->bytes transport backed by a {url: bytes} dict; unknown -> raises."""
    def get(url):
        if url not in mapping:
            raise OSError(f"no fixture for {url}")
        return mapping[url]
    return get


# ---------------------------------------------------------------------------
# parse_feed_date
# ---------------------------------------------------------------------------


def test_parse_feed_date_rfc822():
    from lifeos.web import feeds

    dt = feeds.parse_feed_date("Wed, 22 Jul 2026 09:30:00 +0000")
    assert dt == datetime(2026, 7, 22, 9, 30, tzinfo=timezone.utc)


def test_parse_feed_date_rfc822_with_gmt_and_offset():
    from lifeos.web import feeds

    # GMT label and a non-UTC offset both normalize to tz-aware UTC.
    assert feeds.parse_feed_date("Wed, 22 Jul 2026 11:47:59 GMT") == datetime(
        2026, 7, 22, 11, 47, 59, tzinfo=timezone.utc
    )
    assert feeds.parse_feed_date("Wed, 22 Jul 2026 06:00:00 -0500") == datetime(
        2026, 7, 22, 11, 0, 0, tzinfo=timezone.utc
    )


def test_parse_feed_date_iso_with_z():
    from lifeos.web import feeds

    dt = feeds.parse_feed_date("2026-07-22T14:05:00Z")
    assert dt == datetime(2026, 7, 22, 14, 5, tzinfo=timezone.utc)


def test_parse_feed_date_iso_with_offset():
    from lifeos.web import feeds

    dt = feeds.parse_feed_date("2026-07-21T08:00:00+00:00")
    assert dt == datetime(2026, 7, 21, 8, 0, tzinfo=timezone.utc)


def test_parse_feed_date_none_and_garbage():
    from lifeos.web import feeds

    assert feeds.parse_feed_date(None) is None
    assert feeds.parse_feed_date("") is None
    assert feeds.parse_feed_date("not a date at all") is None


# ---------------------------------------------------------------------------
# fetch_feed — RSS
# ---------------------------------------------------------------------------


def test_fetch_feed_rss_parses_items_and_dates():
    from lifeos.web import feeds

    url = "https://www.muylinux.com/feed/"
    out = feeds.fetch_feed(url, http_get=_fake_get({url: RSS_FEED}))

    assert len(out) == 2
    first = out[0]
    assert first.title == "Kernel 6.20 released today"
    assert first.url == "https://www.muylinux.com/kernel-620"
    assert first.published == datetime(2026, 7, 22, 9, 30, tzinfo=timezone.utc)
    assert "rendimiento" in first.summary
    # Undated item -> published is None (freshness filter will drop it).
    assert out[1].published is None


def test_fetch_feed_respects_limit():
    from lifeos.web import feeds

    url = "https://www.muylinux.com/feed/"
    out = feeds.fetch_feed(url, limit=1, http_get=_fake_get({url: RSS_FEED}))
    assert len(out) == 1


# ---------------------------------------------------------------------------
# fetch_feed — Atom
# ---------------------------------------------------------------------------


def test_fetch_feed_atom_uses_alternate_link_and_dates():
    from lifeos.web import feeds

    url = "https://simonwillison.net/atom/everything/"
    out = feeds.fetch_feed(url, http_get=_fake_get({url: ATOM_FEED}))

    assert len(out) == 2
    first = out[0]
    assert first.title == "A new LLM benchmark"
    # rel="alternate" href wins over the rel="edit" link.
    assert first.url == "https://simonwillison.net/2026/Jul/22/llm-bench/"
    assert first.published == datetime(2026, 7, 22, 14, 5, tzinfo=timezone.utc)
    # Second entry has only <updated> -> used as the published fallback.
    assert out[1].published == datetime(2026, 7, 21, 8, 0, tzinfo=timezone.utc)
    assert out[1].url == "https://simonwillison.net/2026/Jul/21/x/"


# ---------------------------------------------------------------------------
# Defensive behavior — never raises
# ---------------------------------------------------------------------------


def test_fetch_feed_transport_error_returns_empty():
    from lifeos.web import feeds

    def boom(url):
        raise OSError("network down")

    assert feeds.fetch_feed("https://x.example/feed", http_get=boom) == []


def test_fetch_feed_malformed_xml_returns_empty():
    from lifeos.web import feeds

    url = "https://x.example/feed"
    out = feeds.fetch_feed(url, http_get=_fake_get({url: b"<not-xml"}))
    assert out == []


def test_fetch_feed_empty_body_returns_empty():
    from lifeos.web import feeds

    url = "https://x.example/feed"
    assert feeds.fetch_feed(url, http_get=_fake_get({url: b""})) == []
