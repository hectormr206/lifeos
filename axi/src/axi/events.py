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
import shutil
import subprocess
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

_WRITE_QUEUE_MAX = 2000  # bounded to prevent unbounded memory growth under stall
_write_queue: queue.Queue = queue.Queue(maxsize=_WRITE_QUEUE_MAX)
_queue_drop_count = 0       # monotone counter of dropped events (for diagnostics)
_worker_thread: threading.Thread | None = None
_worker_lock = threading.Lock()
_insert_count = 0

# P2.5 — libnotify rate-limit. Keyed by (source, level), value = last fire ts.
_NOTIFY_RATE_LIMIT_S = 300  # 5 minutes
_last_notified: dict[tuple[str, str], float] = {}
_notify_lock = threading.Lock()


def _maybe_notify(source: str, level: str, message: str) -> None:
    """Fire `notify-send` for critical/error events, rate-limited per (source, level).

    Honors `notify_send_enabled` kill switch. Swallows all exceptions — desktop
    notifications must NEVER crash the event log.
    """
    if level not in ("critical", "error"):
        return
    try:
        from axi import config  # lazy
        if not bool(config.get("notify_send_enabled", True)):
            return
    except Exception:  # noqa: BLE001
        return
    binary = shutil.which("notify-send")
    if not binary:
        return
    key = (source, level)
    now = time.time()
    with _notify_lock:
        last = _last_notified.get(key, 0.0)
        if now - last < _NOTIFY_RATE_LIMIT_S:
            return
        _last_notified[key] = now
    urgency = "critical" if level == "critical" else "normal"
    try:
        subprocess.Popen(
            [binary, "-a", "Axi", "-u", urgency, f"Axi · {source}", message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:  # noqa: BLE001
        log.warning("notify-send failed: %s", e)


def _reset_notify_for_tests() -> None:
    with _notify_lock:
        _last_notified.clear()


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

        # Queue SQLite insert on the worker thread (non-blocking).
        import json as _json
        data_json = None
        if entry["data"] is not None:
            try:
                data_json = _json.dumps(entry["data"], ensure_ascii=False)
            except (TypeError, ValueError):
                data_json = None
        try:
            _write_queue.put_nowait({
                "ts": ts,
                "source": entry["source"],
                "level": level,
                "message": entry["message"],
                "data_json": data_json,
            })
        except queue.Full:
            # Queue is full (writer stalled) — drop rather than block the caller.
            global _queue_drop_count
            _queue_drop_count += 1
            # Emit a single rate-limited warning via stdlib logging (never back to events).
            if _queue_drop_count == 1 or _queue_drop_count % 100 == 0:
                log.warning(
                    "events._write_queue full — dropping event (total dropped: %d)",
                    _queue_drop_count,
                )
        _ensure_worker()
        # P2.5 — fire libnotify for critical/error. Best-effort, rate-limited.
        try:
            _maybe_notify(entry["source"], level, entry["message"])
        except Exception as e:  # noqa: BLE001
            log.warning("notify hook swallowed: %s", e)
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
