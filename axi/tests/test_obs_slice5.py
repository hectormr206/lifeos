"""Slice 5 TDD tests — store.query_events + /api/events filters + events_cli.

Coverage:
- 5.1  query_events() with no filters returns events newest-first
- 5.2  query_events(source=...) returns only matching source rows
- 5.3  query_events(level=...) returns only matching level rows
- 5.4  query_events(since_ts=...) returns only events after the cutoff
- 5.5  query_events(limit=...) respects the limit
- 5.6  query_events(offset=...) respects pagination offset
- 5.7  query_events with combined filters (source + level + since_ts)
- 5.8  /api/events?source= filter uses query_events (beyond ring buffer)
- 5.9  /api/events?level= filter uses query_events
- 5.10 /api/events?since_ts= filter uses query_events
- 5.11 /api/events with no params returns recent_events (backward compat)
- 5.12 events_cli --since "1h" is parsed to a correct since_ts (relative)
- 5.13 events_cli --since "30m" / "2d" parses correctly
- 5.14 events_cli formats an event line as: ts level source message [key=value...]
"""
from __future__ import annotations

import json
import time
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _seed(rows: list[dict]) -> None:
    """Insert rows directly into the events table via store.insert_event.

    The autouse fresh_db fixture provides an isolated DB per test.
    """
    from axi import store
    for r in rows:
        store.insert_event(
            r["ts"],
            r["source"],
            r["level"],
            r["message"],
            r.get("data_json"),
        )


# ---------------------------------------------------------------------------
# 5.1 — query_events() newest-first, no filters
# ---------------------------------------------------------------------------


def test_query_events_no_filters_newest_first():
    """query_events() with no filters returns all events ordered newest-first."""
    from axi import store
    now = time.time()
    _seed([
        {"ts": now - 100, "source": "a", "level": "info", "message": "old"},
        {"ts": now - 50,  "source": "b", "level": "info", "message": "mid"},
        {"ts": now - 10,  "source": "c", "level": "info", "message": "new"},
    ])

    results = store.query_events(limit=10)

    assert len(results) == 3
    assert results[0]["message"] == "new"
    assert results[1]["message"] == "mid"
    assert results[2]["message"] == "old"


# ---------------------------------------------------------------------------
# 5.2 — query_events(source=...)
# ---------------------------------------------------------------------------


def test_query_events_source_filter():
    """query_events(source='heartbeat') returns only heartbeat events."""
    from axi import store
    now = time.time()
    _seed([
        {"ts": now - 30, "source": "heartbeat",  "level": "info",    "message": "beat"},
        {"ts": now - 20, "source": "brain.route", "level": "info",   "message": "route"},
        {"ts": now - 10, "source": "heartbeat",  "level": "warning", "message": "revive"},
    ])

    results = store.query_events(source="heartbeat", limit=10)

    assert len(results) == 2
    assert all(r["source"] == "heartbeat" for r in results)
    assert results[0]["message"] == "revive"
    assert results[1]["message"] == "beat"


# ---------------------------------------------------------------------------
# 5.3 — query_events(level=...)
# ---------------------------------------------------------------------------


def test_query_events_level_filter():
    """query_events(level='warning') returns only warning-level events."""
    from axi import store
    now = time.time()
    _seed([
        {"ts": now - 30, "source": "a", "level": "info",    "message": "info-msg"},
        {"ts": now - 20, "source": "b", "level": "warning", "message": "warn-msg"},
        {"ts": now - 10, "source": "c", "level": "error",   "message": "err-msg"},
    ])

    results = store.query_events(level="warning", limit=10)

    assert len(results) == 1
    assert results[0]["level"] == "warning"
    assert results[0]["message"] == "warn-msg"


# ---------------------------------------------------------------------------
# 5.4 — query_events(since_ts=...)
# ---------------------------------------------------------------------------


def test_query_events_since_ts_filter():
    """query_events(since_ts=t) returns only events with ts > t."""
    from axi import store
    now = time.time()
    cutoff = now - 40
    _seed([
        {"ts": now - 60, "source": "x", "level": "info", "message": "before"},
        {"ts": now - 30, "source": "x", "level": "info", "message": "after1"},
        {"ts": now - 10, "source": "x", "level": "info", "message": "after2"},
    ])

    results = store.query_events(since_ts=cutoff, limit=10)

    assert len(results) == 2
    messages = {r["message"] for r in results}
    assert messages == {"after1", "after2"}
    assert "before" not in messages


# ---------------------------------------------------------------------------
# 5.5 — query_events(limit=...)
# ---------------------------------------------------------------------------


def test_query_events_limit():
    """query_events(limit=2) returns at most 2 rows."""
    from axi import store
    now = time.time()
    _seed([
        {"ts": now - i, "source": "s", "level": "info", "message": f"msg{i}"}
        for i in range(5)
    ])

    results = store.query_events(limit=2)

    assert len(results) == 2


# ---------------------------------------------------------------------------
# 5.6 — query_events(offset=...)
# ---------------------------------------------------------------------------


def test_query_events_offset_pagination():
    """query_events(limit=2, offset=2) skips the first 2 newest rows."""
    from axi import store
    now = time.time()
    _seed([
        {"ts": now - i, "source": "s", "level": "info", "message": f"msg{i}"}
        for i in range(5)
    ])

    page1 = store.query_events(limit=2, offset=0)
    page2 = store.query_events(limit=2, offset=2)

    assert len(page1) == 2
    assert len(page2) == 2
    msgs1 = {r["message"] for r in page1}
    msgs2 = {r["message"] for r in page2}
    assert msgs1.isdisjoint(msgs2)


# ---------------------------------------------------------------------------
# 5.7 — combined filters
# ---------------------------------------------------------------------------


def test_query_events_combined_filters():
    """source + level + since_ts all apply together (AND semantics)."""
    from axi import store
    now = time.time()
    cutoff = now - 50
    _seed([
        # Too old
        {"ts": now - 100, "source": "heartbeat", "level": "warning", "message": "old-warn"},
        # Wrong source
        {"ts": now - 30,  "source": "brain",     "level": "warning", "message": "brain-warn"},
        # Wrong level
        {"ts": now - 20,  "source": "heartbeat", "level": "info",    "message": "hb-info"},
        # Matches all three
        {"ts": now - 10,  "source": "heartbeat", "level": "warning", "message": "hb-warn"},
    ])

    results = store.query_events(source="heartbeat", level="warning", since_ts=cutoff, limit=10)

    assert len(results) == 1
    assert results[0]["message"] == "hb-warn"


# ---------------------------------------------------------------------------
# 5.8 — /api/events?source= uses query_events
# ---------------------------------------------------------------------------


def test_api_events_source_filter():
    """/api/events?source=heartbeat calls store.query_events, not just ring."""
    from fastapi.testclient import TestClient
    from axi import dashboard, store

    client = TestClient(dashboard.app, raise_server_exceptions=False)

    mock_results = [
        {"ts": 1000.0, "source": "heartbeat", "level": "info", "message": "beat", "data": None}
    ]

    with patch.object(store, "query_events", return_value=mock_results) as mock_qe:
        resp = client.get("/api/events?source=heartbeat")

    assert resp.status_code == 200
    data = resp.json()
    assert "events" in data
    mock_qe.assert_called_once()
    kwargs = mock_qe.call_args.kwargs
    assert kwargs.get("source") == "heartbeat"


# ---------------------------------------------------------------------------
# 5.9 — /api/events?level= uses query_events
# ---------------------------------------------------------------------------


def test_api_events_level_filter_uses_query_events():
    """/api/events?level=warning calls store.query_events."""
    from fastapi.testclient import TestClient
    from axi import dashboard, store

    client = TestClient(dashboard.app, raise_server_exceptions=False)

    with patch.object(store, "query_events", return_value=[]) as mock_qe:
        resp = client.get("/api/events?level=warning")

    assert resp.status_code == 200
    mock_qe.assert_called_once()
    kwargs = mock_qe.call_args.kwargs
    assert kwargs.get("level") == "warning"


# ---------------------------------------------------------------------------
# 5.10 — /api/events?since_ts= uses query_events
# ---------------------------------------------------------------------------


def test_api_events_since_ts_filter_uses_query_events():
    """/api/events?since_ts=1000.5 calls store.query_events with since_ts."""
    from fastapi.testclient import TestClient
    from axi import dashboard, store

    client = TestClient(dashboard.app, raise_server_exceptions=False)

    with patch.object(store, "query_events", return_value=[]) as mock_qe:
        resp = client.get("/api/events?since_ts=1000.5")

    assert resp.status_code == 200
    mock_qe.assert_called_once()
    kwargs = mock_qe.call_args.kwargs
    assert kwargs.get("since_ts") == pytest.approx(1000.5)


# ---------------------------------------------------------------------------
# 5.11 — /api/events with no filters uses recent_events (backward compat)
# ---------------------------------------------------------------------------


def test_api_events_no_params_uses_ring_buffer():
    """/api/events with no query params uses events.recent_events (ring buffer)."""
    from fastapi.testclient import TestClient
    from axi import dashboard, events, store

    client = TestClient(dashboard.app, raise_server_exceptions=False)

    mock_ring = [
        {"ts": 1.0, "source": "s", "level": "info", "message": "m", "data": None, "unread": False}
    ]

    with patch.object(events, "recent_events", return_value=mock_ring) as mock_re, \
         patch.object(store, "query_events", return_value=[]) as mock_qe:
        resp = client.get("/api/events")

    assert resp.status_code == 200
    data = resp.json()
    assert len(data["events"]) == 1
    mock_re.assert_called_once()
    mock_qe.assert_not_called()


# ---------------------------------------------------------------------------
# 5.12 — events_cli --since "1h" parsing
# ---------------------------------------------------------------------------


def test_events_cli_since_parsing_1h():
    """parse_since('1h') returns a unix timestamp ~1 hour before now."""
    from axi import events_cli

    before = time.time()
    ts = events_cli.parse_since("1h")
    after = time.time()

    expected = before - 3600
    assert abs(ts - expected) < 2.0, f"Expected ~{expected}, got {ts}"


# ---------------------------------------------------------------------------
# 5.13 — events_cli --since "30m" / "2d" / invalid
# ---------------------------------------------------------------------------


def test_events_cli_since_parsing_30m():
    """parse_since('30m') returns a unix timestamp ~30 minutes before now."""
    from axi import events_cli

    before = time.time()
    ts = events_cli.parse_since("30m")

    expected = before - 30 * 60
    assert abs(ts - expected) < 2.0


def test_events_cli_since_parsing_2d():
    """parse_since('2d') returns a unix timestamp ~2 days before now."""
    from axi import events_cli

    before = time.time()
    ts = events_cli.parse_since("2d")

    expected = before - 2 * 86400
    assert abs(ts - expected) < 2.0


def test_events_cli_since_parsing_invalid():
    """parse_since with an unrecognized format raises ValueError."""
    from axi import events_cli

    with pytest.raises(ValueError, match="since"):
        events_cli.parse_since("5x")


# ---------------------------------------------------------------------------
# 5.14 — events_cli event line formatting
# ---------------------------------------------------------------------------


def test_events_cli_format_event_line_no_data():
    """format_event_line produces a line containing ts, level, source, message."""
    from axi import events_cli

    event = {
        "ts": 1000.0,
        "source": "heartbeat",
        "level": "info",
        "message": "service is up",
        "data": None,
    }
    line = events_cli.format_event_line(event)

    assert "heartbeat" in line
    assert "INFO" in line or "info" in line
    assert "service is up" in line
    assert line.strip() != ""


def test_events_cli_format_event_line_with_data():
    """format_event_line appends key=value pairs from data dict."""
    from axi import events_cli

    event = {
        "ts": 1000.0,
        "source": "brain.route",
        "level": "info",
        "message": "routed",
        "data": {"engine": "vt", "trigger": "chat"},
    }
    line = events_cli.format_event_line(event)

    assert "engine=vt" in line
    assert "trigger=chat" in line
