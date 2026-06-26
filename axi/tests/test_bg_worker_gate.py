"""Tests for the AXI_DISABLE_BG_WORKERS process-level gate.

Verifies that:
  - With the gate ON (default in tests), implicit auto-triggers do NOT start
    background threads.
  - With the gate OFF (production default), the implicit triggers DO start the
    workers, and the threads are properly cleaned up.
  - The gate is respected by events.py and brain.py as well.
"""
from __future__ import annotations

import os
import threading
import time


def _count_live(name: str) -> int:
    """Return the number of live threads with the given name."""
    return sum(1 for t in threading.enumerate() if t.name == name and t.is_alive())


# ─────────────────────────── embed worker gate ───────────────────────────────

def test_gate_on_embed_worker_does_not_start(tmp_path, monkeypatch):
    """With AXI_DISABLE_BG_WORKERS=1, trigger_embed_for_node must NOT start
    the axi-embed-worker thread."""
    from axi import store

    # Ensure gate is ON (conftest already sets the env var before import, but
    # we re-assert the module-level flag here for clarity).
    assert store._BG_WORKERS_DISABLED, (
        "Expected _BG_WORKERS_DISABLED=True; conftest must set AXI_DISABLE_BG_WORKERS=1"
    )

    before = _count_live("axi-embed-worker")
    store.trigger_embed_for_node(9999)
    time.sleep(0.05)  # brief pause to let any accidentally spawned thread register
    after = _count_live("axi-embed-worker")
    assert after == before, (
        f"axi-embed-worker thread was started despite AXI_DISABLE_BG_WORKERS=1 "
        f"(before={before}, after={after})"
    )


def test_gate_off_embed_worker_starts(tmp_path, monkeypatch):
    """With AXI_DISABLE_BG_WORKERS unset AND _EMBED_WRITER_ENABLED=True,
    trigger_embed_for_node MUST start the axi-embed-worker thread.

    Both gates must be cleared to simulate the daemon (single-writer) process.
    The dashboard and other readers never call enable_embed_writer() so
    _EMBED_WRITER_ENABLED stays False and the worker never starts there.
    Cleans up after itself."""
    from axi import store

    # Override both module-level flags to simulate the production daemon path.
    monkeypatch.setattr(store, "_BG_WORKERS_DISABLED", False)
    monkeypatch.setattr(store, "_EMBED_WRITER_ENABLED", True)

    store.stop_embed_worker()  # ensure clean state
    before = _count_live("axi-embed-worker")
    store.trigger_embed_for_node(1)
    time.sleep(0.1)  # give the thread a moment to start
    after = _count_live("axi-embed-worker")
    store.stop_embed_worker()  # clean up
    assert after > before, (
        "Expected axi-embed-worker to start when _BG_WORKERS_DISABLED=False "
        "and _EMBED_WRITER_ENABLED=True (daemon process simulation)"
    )


# ─────────────────────────── events writer gate ───────────────────────────────

def test_gate_on_events_writer_does_not_start(monkeypatch):
    """With AXI_DISABLE_BG_WORKERS=1, log_event must NOT start the
    axi-events-writer thread."""
    from axi import events

    assert events._BG_WORKERS_DISABLED, (
        "Expected events._BG_WORKERS_DISABLED=True; conftest must set AXI_DISABLE_BG_WORKERS=1"
    )

    # Make sure no writer is running from a prior test.
    events.stop_events_writer()
    before = _count_live("axi-events-writer")
    events.log_info("test.gate", "gate-on test event")
    time.sleep(0.05)
    after = _count_live("axi-events-writer")
    assert after == before, (
        f"axi-events-writer thread was started despite AXI_DISABLE_BG_WORKERS=1 "
        f"(before={before}, after={after})"
    )


def test_gate_off_events_writer_starts(monkeypatch):
    """With AXI_DISABLE_BG_WORKERS unset, log_event MUST call _ensure_worker
    which creates an axi-events-writer thread. Verifies the thread object was
    created (it may exit quickly if the DB is not accessible in test context).
    Cleans up after itself."""
    from axi import events

    monkeypatch.setattr(events, "_BG_WORKERS_DISABLED", False)
    events.stop_events_writer()  # ensure clean state — resets _worker_thread to None
    assert events._worker_thread is None, "Expected _worker_thread=None after stop"
    events.log_info("test.gate", "gate-off test event")
    # Give the thread a moment to be registered. The thread may exit quickly
    # (DB not accessible in test context) but it MUST have been created.
    time.sleep(0.1)
    thread_created = events._worker_thread is not None
    events.stop_events_writer()  # clean up
    assert thread_created, (
        "Expected _ensure_worker() to create an axi-events-writer thread "
        "when AXI_DISABLE_BG_WORKERS is off"
    )


# ─────────────────────────── brain metric gate ───────────────────────────────

def test_gate_on_brain_metric_does_not_spawn(monkeypatch):
    """With AXI_DISABLE_BG_WORKERS=1, _record_metric_async must NOT spawn an
    axi-brain-metric thread."""
    from axi import brain

    assert brain._BG_WORKERS_DISABLED, (
        "Expected brain._BG_WORKERS_DISABLED=True; conftest must set AXI_DISABLE_BG_WORKERS=1"
    )

    before = _count_live("axi-brain-metric")
    brain._record_metric_async(latency_ms=100, ok=True, error=None, response_data=None)
    time.sleep(0.05)
    after = _count_live("axi-brain-metric")
    assert after == before, (
        f"axi-brain-metric thread was spawned despite AXI_DISABLE_BG_WORKERS=1 "
        f"(before={before}, after={after})"
    )


def test_gate_off_brain_metric_spawns(monkeypatch):
    """With AXI_DISABLE_BG_WORKERS unset, _record_metric_async MUST spawn an
    axi-brain-metric thread. Waits for it to finish so the DB is not touched
    after the fixture tears down."""
    from axi import brain

    monkeypatch.setattr(brain, "_BG_WORKERS_DISABLED", False)
    before = _count_live("axi-brain-metric")
    brain._record_metric_async(latency_ms=50, ok=True, error=None, response_data=None)
    # Wait up to 1 s for the thread to appear and finish.
    deadline = time.monotonic() + 1.0
    spawned = False
    while time.monotonic() < deadline:
        if _count_live("axi-brain-metric") > before:
            spawned = True
        time.sleep(0.02)
    # Let any spawned thread finish so it doesn't race with fixture teardown.
    extra_deadline = time.monotonic() + 1.0
    while time.monotonic() < extra_deadline:
        if _count_live("axi-brain-metric") == 0:
            break
        time.sleep(0.02)
    assert spawned, (
        "Expected axi-brain-metric thread to be spawned when AXI_DISABLE_BG_WORKERS is off"
    )
