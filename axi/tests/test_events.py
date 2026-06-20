"""Tests for the event log (PRD P0.1).

The autouse `fresh_db` fixture in conftest.py rewires `axi.store` to a
temp SQLite DB, so every test starts with an empty `events` table.
"""
from __future__ import annotations

import pytest

from axi import events, store


@pytest.fixture(autouse=True)
def fresh_events(monkeypatch):
    """Reset the ring buffer and event-writer state between tests."""
    events._reset_for_tests()
    # Re-enable by default (some tests will flip it off).
    from axi import config
    monkeypatch.setattr(config, "_cache", None)
    yield
    events._reset_for_tests()


def test_log_event_writes_to_ring_and_db():
    events.log_event("test", "info", "hello world", data={"k": "v"})
    events._flush_for_tests()

    rows = events.recent_events(limit=10)
    assert len(rows) == 1
    assert rows[0]["source"] == "test"
    assert rows[0]["level"] == "info"
    assert rows[0]["message"] == "hello world"
    assert rows[0]["data"] == {"k": "v"}
    assert rows[0]["unread"] is True

    # SQLite persistence — events live in the separate events.db, not memory.db.
    c = store._connect_events()
    db_rows = c.execute("SELECT source, level, message FROM events").fetchall()
    assert len(db_rows) == 1
    assert db_rows[0]["message"] == "hello world"


def test_level_filter():
    events.log_event("a", "info", "an info")
    events.log_event("a", "error", "an error")
    events.log_event("a", "critical", "a crit")

    only_err = events.recent_events(limit=10, level="error")
    assert len(only_err) == 1
    assert only_err[0]["level"] == "error"

    crits = events.recent_events(limit=10, level="critical")
    assert len(crits) == 1


def test_unknown_level_is_ignored():
    events.log_event("a", "bogus", "nope")
    assert events.recent_events(limit=10) == []


def test_kill_switch_disables(monkeypatch):
    from axi import config
    monkeypatch.setattr(config, "_cache", dict(config.DEFAULTS, events_enabled=False))
    events.log_event("test", "error", "should not appear")
    events._flush_for_tests()
    assert events.recent_events(limit=10) == []


def test_init_db_idempotent():
    # Should not raise on second call (cross-cutting convention §9.2).
    store.init_db()
    store.init_db()


def test_unread_critical_count_and_mark_read():
    events.log_event("a", "info", "x")
    events.log_event("a", "critical", "boom")
    events.log_event("a", "critical", "boom2")
    assert events.unread_critical_count() == 2

    events.mark_all_read()
    assert events.unread_critical_count() == 0
    # Entries still in the buffer; just marked read.
    assert len(events.recent_events(limit=10)) == 3


def test_convenience_helpers():
    events.log_info("s", "i")
    events.log_warning("s", "w")
    events.log_error("s", "e")
    events.log_critical("s", "c")
    rows = events.recent_events(limit=10)
    levels = {r["level"] for r in rows}
    assert levels == {"info", "warning", "error", "critical"}


def test_trim_events_keeps_only_recent():
    for i in range(10):
        store.insert_event(float(i), "x", "info", f"msg {i}", None)
    store.trim_events(keep=3)
    c = store._connect_events()
    n = c.execute("SELECT COUNT(*) AS n FROM events").fetchone()["n"]
    assert n == 3
    # Most recent (highest ts) survive.
    msgs = [r["message"] for r in c.execute("SELECT message FROM events ORDER BY ts").fetchall()]
    assert msgs == ["msg 7", "msg 8", "msg 9"]


def test_recent_events_returns_newest_first():
    events.log_event("a", "info", "first")
    events.log_event("a", "info", "second")
    rows = events.recent_events(limit=10)
    assert rows[0]["message"] == "second"
    assert rows[1]["message"] == "first"
