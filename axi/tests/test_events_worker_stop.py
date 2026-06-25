"""Tests for the axi-events-writer worker stop/teardown behaviour.

TDD red phase: these tests define the contract for stop_events_writer().
They are written BEFORE the implementation and must FAIL until events.py
is updated with the stop machinery.

Tests:
  1. stop_events_writer reaps the worker thread.
  2. Worker refuses to touch the DB after stop is signalled.
  3. stop_events_writer is safe to call when the worker was never started.
"""
from __future__ import annotations

import threading
import time

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _writer_threads() -> list[threading.Thread]:
    """Return all currently alive axi-events-writer threads."""
    return [t for t in threading.enumerate()
            if t.name == "axi-events-writer" and t.is_alive()]


# ---------------------------------------------------------------------------
# Test 1: stop_events_writer reaps the worker thread
# ---------------------------------------------------------------------------

def test_stop_events_writer_reaps_worker():
    """After stop_events_writer(), no axi-events-writer thread remains alive."""
    from axi import events as _events

    try:
        # Enqueue an event so the worker spins up.
        _events.log_event("test.source", "info", "reap-test message")
        # Give the worker a moment to start.
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            if _writer_threads():
                break
            time.sleep(0.01)

        # Now stop it.
        _events.stop_events_writer()

        # No alive worker should remain.
        alive = _writer_threads()
        assert alive == [], (
            f"Expected no axi-events-writer threads after stop, "
            f"found: {[t.ident for t in alive]}"
        )
    finally:
        _events.stop_events_writer()
        _events._reset_for_tests()


# ---------------------------------------------------------------------------
# Test 2: Worker refuses to call store.insert_event after stop is signalled
# ---------------------------------------------------------------------------

def test_worker_refuses_insert_after_stop(monkeypatch):
    """Worker must NOT call store.insert_event after _writer_stop is set."""
    from axi import events as _events
    from axi import store

    calls: list[tuple] = []

    def _fake_insert(ts, source, level, message, data_json):
        calls.append((ts, source, level, message, data_json))

    monkeypatch.setattr(store, "insert_event", _fake_insert)

    try:
        # Reset to a clean state (no live worker).
        _events.stop_events_writer()
        _events._reset_for_tests()

        # Signal stop BEFORE the worker processes anything.
        _events._writer_stop.set()

        # Enqueue an item (bypassing log_event to avoid _ensure_worker starting a thread
        # that clears the stop flag).
        _events._write_queue.put_nowait({
            "ts": time.time(),
            "source": "test.source",
            "level": "info",
            "message": "should not be inserted",
            "data_json": None,
        })

        # Start a worker manually. It should see the stop flag and exit without
        # calling store.insert_event.
        t = threading.Thread(target=_events._worker_loop, name="axi-events-writer", daemon=True)
        t.start()
        # Put a sentinel to unblock the get() in case the worker didn't see the flag first.
        _events._write_queue.put(None)
        t.join(timeout=2.0)

        assert not t.is_alive(), "Worker thread did not exit within timeout"
        assert calls == [], (
            f"store.insert_event was called {len(calls)} time(s) after stop was set"
        )
    finally:
        _events._writer_stop.clear()
        _events.stop_events_writer()
        _events._reset_for_tests()


# ---------------------------------------------------------------------------
# Test 3: stop_events_writer is safe to call when never started
# ---------------------------------------------------------------------------

def test_stop_events_writer_safe_when_never_started():
    """stop_events_writer() must not raise even if the worker was never started."""
    from axi import events as _events

    # Ensure clean state: stop any running worker first.
    _events.stop_events_writer()
    _events._reset_for_tests()

    # Now call stop again on an idle module — must be fast and exception-free.
    start = time.monotonic()
    try:
        _events.stop_events_writer()
    except Exception as exc:  # noqa: BLE001
        pytest.fail(f"stop_events_writer() raised unexpectedly: {exc!r}")

    elapsed = time.monotonic() - start
    assert elapsed < 1.0, f"stop_events_writer() took too long on idle module: {elapsed:.2f}s"
