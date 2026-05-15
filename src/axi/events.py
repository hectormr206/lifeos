"""Structured event log for Axi (PRD P0.1).

Two-tier event log:

* In-memory ring buffer (`collections.deque`, last 200 events) — fast read
  path for the dashboard `/api/events` and the header red-dot indicator.
* SQLite `events` table — persists across restarts. Writes happen on a
  background thread so callers never block on disk I/O.

Public API:
    log_event(source, level, message, *, data=None)
    log_info / log_warning / log_error / log_critical (source, message, data=None)
    recent_events(limit=50, level=None) -> list[dict]
    mark_all_read() -> None
    unread_critical_count() -> int

This module MUST NEVER crash a caller. Any internal failure is logged via
stdlib `logging` and swallowed.

Kill switch: `events_enabled` in config (default True). When False every
`log_event` call is a no-op.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from collections import deque
from typing import Any

log = logging.getLogger("axi.events")

EVENT_LEVELS: tuple[str, ...] = ("info", "warning", "error", "critical")
_RING_MAX = 200
_TRIM_KEEP = 5000
_TRIM_EVERY = 100

# ─────────────────────────── module-level state ─────────────────────────

_ring: deque[dict[str, Any]] = deque(maxlen=_RING_MAX)
_ring_lock = threading.Lock()

_write_queue: queue.Queue = queue.Queue()
_worker_thread: threading.Thread | None = None
_worker_lock = threading.Lock()
_insert_count = 0


# ─────────────────────────── background worker ──────────────────────────

def _ensure_worker() -> None:
    global _worker_thread
    if _worker_thread is not None and _worker_thread.is_alive():
        return
    with _worker_lock:
        if _worker_thread is not None and _worker_thread.is_alive():
            return
        t = threading.Thread(target=_worker_loop, name="axi-events-writer", daemon=True)
        t.start()
        _worker_thread = t


def _worker_loop() -> None:
    global _insert_count
    while True:
        item = _write_queue.get()
        if item is None:  # sentinel for tests
            return
        try:
            from axi import store  # lazy to avoid import cycles
            store.insert_event(
                item["ts"],
                item["source"],
                item["level"],
                item["message"],
                item.get("data_json"),
            )
            _insert_count += 1
            if _insert_count % _TRIM_EVERY == 0:
                try:
                    store.trim_events(_TRIM_KEEP)
                except Exception as e:  # noqa: BLE001
                    log.warning("events trim failed: %s", e)
        except Exception as e:  # noqa: BLE001
            log.warning("event SQLite insert failed: %s", e)


# ─────────────────────────────── public API ─────────────────────────────

def _enabled() -> bool:
    try:
        from axi import config  # lazy
        return bool(config.get("events_enabled", True))
    except Exception:  # noqa: BLE001
        return True


def log_event(
    source: str,
    level: str,
    message: str,
    *,
    data: dict[str, Any] | None = None,
) -> None:
    """Record an event. Never raises; failures are swallowed and logged."""
    try:
        if not _enabled():
            return
        if level not in EVENT_LEVELS:
            log.warning("log_event: unknown level %r (allowed: %s)", level, EVENT_LEVELS)
            return
        ts = time.time()
        entry = {
            "ts": ts,
            "source": str(source),
            "level": level,
            "message": str(message),
            "data": dict(data) if isinstance(data, dict) else None,
            "unread": True,
        }
        with _ring_lock:
            _ring.append(entry)

        # Queue SQLite insert on the worker thread.
        import json as _json
        data_json = None
        if entry["data"] is not None:
            try:
                data_json = _json.dumps(entry["data"], ensure_ascii=False)
            except (TypeError, ValueError):
                data_json = None
        _write_queue.put({
            "ts": ts,
            "source": entry["source"],
            "level": level,
            "message": entry["message"],
            "data_json": data_json,
        })
        _ensure_worker()
    except Exception as e:  # noqa: BLE001 — events must never crash callers
        log.warning("log_event swallowed exception: %s", e)


def log_info(source: str, message: str, data: dict[str, Any] | None = None) -> None:
    log_event(source, "info", message, data=data)


def log_warning(source: str, message: str, data: dict[str, Any] | None = None) -> None:
    log_event(source, "warning", message, data=data)


def log_error(source: str, message: str, data: dict[str, Any] | None = None) -> None:
    log_event(source, "error", message, data=data)


def log_critical(source: str, message: str, data: dict[str, Any] | None = None) -> None:
    log_event(source, "critical", message, data=data)


def recent_events(limit: int = 50, level: str | None = None) -> list[dict[str, Any]]:
    """Return the most recent events from the ring buffer (newest first)."""
    if limit <= 0:
        return []
    with _ring_lock:
        items = list(_ring)
    if level:
        if level not in EVENT_LEVELS:
            return []
        items = [e for e in items if e["level"] == level]
    items.reverse()  # newest first
    out: list[dict[str, Any]] = []
    for e in items[:limit]:
        out.append({
            "ts": e["ts"],
            "source": e["source"],
            "level": e["level"],
            "message": e["message"],
            "data": e["data"],
            "unread": e["unread"],
        })
    return out


def mark_all_read() -> None:
    with _ring_lock:
        for e in _ring:
            e["unread"] = False


def unread_critical_count() -> int:
    with _ring_lock:
        return sum(1 for e in _ring if e["unread"] and e["level"] == "critical")


# ─────────────────────────── test helpers ───────────────────────────────

def _reset_for_tests() -> None:
    """Clear ring buffer and drain queue. Tests only."""
    global _insert_count
    with _ring_lock:
        _ring.clear()
    try:
        while True:
            _write_queue.get_nowait()
    except queue.Empty:
        pass
    _insert_count = 0


def _flush_for_tests(timeout: float = 2.0) -> None:
    """Wait for the background worker to drain. Tests only."""
    _ensure_worker()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _write_queue.empty():
            # Give the worker a tick to finish the in-flight item.
            time.sleep(0.02)
            if _write_queue.empty():
                return
        time.sleep(0.01)
