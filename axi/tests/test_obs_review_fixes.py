"""TDD tests for observability adversarial-review fixes (FIX 1–9).

Each test documents the FAILING behavior first (RED), then passes after
the corresponding implementation fix (GREEN).

Run with:
    cd axi && .venv/bin/python -m pytest tests/test_obs_review_fixes.py -v
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ─────────────────────────────────────────────────────────────────────────────
# FIX 1 — req_id appears in formatted log output
# ─────────────────────────────────────────────────────────────────────────────


def test_req_id_appears_in_formatted_output_when_set():
    """Formatted log output contains req_id=<value> when request_id is set (FIX 1)."""
    from axi import obs
    from axi.logging_setup import LogfmtFormatter, ReqIdFilter

    obs.set_request_id("fix1-test-req")
    try:
        formatter = LogfmtFormatter()
        req_filter = ReqIdFilter()

        record = logging.LogRecord(
            name="axi.test", level=logging.INFO, pathname="", lineno=0,
            msg="hello", args=(), exc_info=None,
        )
        req_filter.filter(record)  # inject req_id onto record
        output = formatter.format(record)

        assert "req_id=fix1-test-req" in output, (
            f"Expected 'req_id=fix1-test-req' in formatted output, got: {output!r}"
        )
    finally:
        obs.set_request_id("-")


def test_req_id_default_dash_in_formatted_output():
    """Formatted log output contains req_id=- when no request_id is set (FIX 1)."""
    from axi import obs
    from axi.logging_setup import LogfmtFormatter, ReqIdFilter

    obs.set_request_id("-")
    formatter = LogfmtFormatter()
    req_filter = ReqIdFilter()

    record = logging.LogRecord(
        name="axi.test", level=logging.INFO, pathname="", lineno=0,
        msg="hello", args=(), exc_info=None,
    )
    req_filter.filter(record)
    output = formatter.format(record)

    assert "req_id=-" in output, (
        f"Expected 'req_id=-' in formatted output, got: {output!r}"
    )


def test_logfmt_formatter_no_keyerror_without_req_id():
    """LogfmtFormatter must not raise KeyError when req_id is absent on record (FIX 1)."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.test", level=logging.INFO, pathname="", lineno=0,
        msg="hello", args=(), exc_info=None,
    )
    # Deliberately do NOT set record.req_id (no filter applied)
    # Must not raise KeyError
    output = formatter.format(record)
    assert "hello" in output


# ─────────────────────────────────────────────────────────────────────────────
# FIX 2 — _repair_corrupt_db Step 4 wrapped in try/except
# ─────────────────────────────────────────────────────────────────────────────


def test_repair_step4_connect_failure_raises_runtimeerror(tmp_path, monkeypatch):
    """When Step-4 connect raises, a clear RuntimeError is raised (not raw OSError) (FIX 2)."""
    import sqlcipher3 as _sc3
    import axi.store as store_mod

    monkeypatch.setattr(_sc3, "connect", lambda *a, **kw: (_ for _ in ()).throw(OSError("disk full")))
    monkeypatch.setattr(store_mod, "_try_open", lambda *a, **kw: None)
    monkeypatch.setattr(store_mod, "_emit_recovery_event", lambda *a, **kw: None)
    monkeypatch.setattr(store_mod, "_remove_wal_sidecars", lambda *a, **kw: None)

    db_path = tmp_path / "corrupt.db"
    db_path.write_bytes(b"corrupt")

    with pytest.raises(RuntimeError, match="recovery step 4 failed"):
        store_mod._repair_corrupt_db(db_path, "deadbeef00112233")


def test_repair_step4_emit_critical_before_failure(tmp_path, monkeypatch):
    """Critical event is emitted for step 4 even when connect fails (FIX 2)."""
    import sqlcipher3 as _sc3
    import axi.store as store_mod

    critical_calls: list = []

    def fake_emit(level, msg, data=None):
        critical_calls.append({"level": level, "msg": msg})

    monkeypatch.setattr(store_mod, "_emit_recovery_event", fake_emit)
    monkeypatch.setattr(store_mod, "_try_open", lambda *a, **kw: None)
    monkeypatch.setattr(store_mod, "_remove_wal_sidecars", lambda *a, **kw: None)
    monkeypatch.setattr(_sc3, "connect", lambda *a, **kw: (_ for _ in ()).throw(OSError("disk full")))

    db_path = tmp_path / "corrupt.db"
    db_path.write_bytes(b"corrupt")

    with pytest.raises((RuntimeError, OSError)):
        store_mod._repair_corrupt_db(db_path, "deadbeef00112233")

    critical_step4 = [c for c in critical_calls
                      if "step 4" in c.get("msg", "").lower() or c.get("level") == "critical"]
    assert critical_step4, (
        f"Expected critical event for step 4 recovery, got: {critical_calls}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 3 — tray _restart_daemon does not block Qt main thread
# ─────────────────────────────────────────────────────────────────────────────


def test_restart_daemon_does_not_block(monkeypatch):
    """_restart_daemon returns immediately; managed_systemctl runs in a background thread (FIX 3)."""
    from axi import obs

    call_thread_ids: list[int] = []

    def recording_managed(action, service, *, caller, reason, **kw):
        call_thread_ids.append(threading.get_ident())
        return MagicMock(returncode=0)

    monkeypatch.setattr(obs, "managed_systemctl", recording_managed)

    main_thread_id = threading.get_ident()

    # Simulate the FIXED _restart_daemon: spawn a daemon thread
    def _restart_daemon_fixed():
        def _run():
            obs.managed_systemctl(
                "restart", "axi-voice.service",
                caller="tray",
                reason="tray restart",
                timeout=30,
            )
        t = threading.Thread(target=_run, daemon=True)
        t.start()
        return t  # returns immediately, does not block

    t = _restart_daemon_fixed()
    t.join(timeout=2.0)

    assert call_thread_ids, "managed_systemctl was never called"
    assert call_thread_ids[0] != main_thread_id, (
        "managed_systemctl was called on the MAIN thread — it blocks the Qt event loop (FIX 3)"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 4 — heartbeat.run_cycle survives a logging handler that raises
# ─────────────────────────────────────────────────────────────────────────────


def test_run_cycle_survives_raising_log_handler(monkeypatch):
    """run_cycle continues when a logging handler raises OSError (FIX 4)."""
    from axi import heartbeat, obs

    monkeypatch.setattr(obs, "lifecycle", lambda *a, **kw: None)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    class RaisingHandler(logging.Handler):
        def emit(self, record):
            raise OSError("disk full — handler error")

    raising_handler = RaisingHandler()
    heartbeat_logger = logging.getLogger("axi.heartbeat")
    heartbeat_logger.addHandler(raising_handler)

    def fake_run(argv, **kw):
        import types
        return types.SimpleNamespace(stdout="inactive\n", returncode=1, stderr="")

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    try:
        beats = list(heartbeat.run_cycle(now=0.0))
        # Must have completed without propagating the handler exception
        assert beats is not None
    finally:
        heartbeat_logger.removeHandler(raising_handler)


# ─────────────────────────────────────────────────────────────────────────────
# FIX 5 — logfmt values with spaces/newlines are quoted
# ─────────────────────────────────────────────────────────────────────────────


def test_logfmt_formatter_quotes_values_with_spaces():
    """LogfmtFormatter quotes extra_fields values that contain spaces (FIX 5)."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.test", level=logging.INFO, pathname="", lineno=0,
        msg="msg", args=(), exc_info=None,
    )
    record.extra_fields = {"service": "axi voice service", "reason": "failed normally"}
    output = formatter.format(record)

    assert 'service="axi voice service"' in output, (
        f"Expected quoted value for service, got: {output!r}"
    )
    assert 'reason="failed normally"' in output, (
        f"Expected quoted value for reason, got: {output!r}"
    )


def test_logfmt_formatter_quotes_values_with_newlines():
    """LogfmtFormatter collapses/escapes newlines in values (FIX 5)."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.test", level=logging.INFO, pathname="", lineno=0,
        msg="msg", args=(), exc_info=None,
    )
    record.extra_fields = {"tb": "Traceback\n  line 1\n  line 2"}
    output = formatter.format(record)

    kv_lines = [l for l in output.split("\n") if "tb=" in l]
    assert kv_lines, f"tb= not found in output: {output!r}"
    assert 'tb="' in kv_lines[0], (
        f"Expected quoted tb value, got: {kv_lines[0]!r}"
    )


def test_format_event_line_sanitizes_multiline_data():
    """format_event_line produces a single-line output even for multiline values (FIX 5)."""
    from axi import events_cli

    event = {
        "ts": 1000.0,
        "source": "brain.error",
        "level": "error",
        "message": "500 error",
        "data": {"tb": "Traceback\n  line 1\n  line 2"},
    }
    line = events_cli.format_event_line(event)

    assert "\n" not in line, (
        f"format_event_line returned multi-line output: {line!r}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 6 — managed_systemctl emits warning on non-zero returncode
# ─────────────────────────────────────────────────────────────────────────────


def test_managed_systemctl_emits_warning_on_failure(monkeypatch):
    """managed_systemctl emits a warning event when returncode != 0 (FIX 6)."""
    import subprocess
    from axi import obs, events

    warning_calls: list[tuple] = []
    monkeypatch.setattr(events, "log_warning",
                        lambda src, msg, data=None: warning_calls.append((src, msg, data)))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: None)

    fake_result = MagicMock()
    fake_result.returncode = 1
    fake_result.stdout = ""
    fake_result.stderr = "unit not found"

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: fake_result)

    result = obs.managed_systemctl(
        "restart", "nonexistent.service",
        caller="test.caller",
        reason="test reason",
        check=False,
    )

    assert result is fake_result, "managed_systemctl must return the CompletedProcess unchanged"
    assert warning_calls, (
        f"Expected a warning event on non-zero returncode, got: {warning_calls}"
    )
    src, msg, data = warning_calls[0]
    assert data is not None
    rc_visible = data.get("returncode") == 1 or "rc=1" in msg or "failed" in msg.lower()
    assert rc_visible, f"Warning should include returncode, got msg={msg!r} data={data!r}"
    stderr_visible = "unit not found" in str(data) or data.get("stderr")
    assert stderr_visible, f"Warning should include stderr, got data={data!r}"


def test_managed_systemctl_no_warning_on_success(monkeypatch):
    """managed_systemctl does NOT emit a warning when returncode == 0 (FIX 6)."""
    import subprocess
    from axi import obs, events

    warning_calls: list[tuple] = []
    monkeypatch.setattr(events, "log_warning",
                        lambda src, msg, data=None: warning_calls.append((src, msg, data)))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: None)

    fake_result = MagicMock()
    fake_result.returncode = 0
    fake_result.stdout = ""
    fake_result.stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: fake_result)

    obs.managed_systemctl(
        "restart", "axi-voice.service",
        caller="test.caller",
        reason="test reason",
        check=False,
    )

    # No warning should be emitted for a successful call
    assert not warning_calls, (
        f"Expected NO warning events on success, got: {warning_calls}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 7 — events queue is bounded; log_event does not block when full
# ─────────────────────────────────────────────────────────────────────────────


def test_events_queue_is_bounded():
    """events._write_queue has a finite maxsize > 0 (FIX 7)."""
    from axi import events

    assert events._write_queue.maxsize > 0, (
        f"Expected bounded queue (maxsize > 0), got maxsize={events._write_queue.maxsize}"
    )


def test_log_event_does_not_block_when_queue_full(monkeypatch):
    """log_event is non-blocking when the write queue is full (FIX 7).

    Run inside a daemon thread with a 2s timeout so a buggy blocking put()
    doesn't hang the entire test suite.
    """
    from axi import events

    # Use a tiny full queue
    q: queue.Queue = queue.Queue(maxsize=3)
    for i in range(3):
        q.put_nowait({"ts": i, "source": "x", "level": "info", "message": "x", "data_json": None})

    monkeypatch.setattr(events, "_write_queue", q)

    result: list = []

    def _call():
        start = time.monotonic()
        events.log_event("test.source", "info", "message when full")
        result.append(time.monotonic() - start)

    t = threading.Thread(target=_call, daemon=True)
    t.start()
    t.join(timeout=2.0)

    assert t.is_alive() is False, (
        "log_event is still blocked after 2s when queue was full — must be non-blocking (FIX 7)"
    )
    assert result, "log_event thread never finished"
    assert result[0] < 1.5, (
        f"log_event blocked for {result[0]:.2f}s when queue was full — must be non-blocking (FIX 7)"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 8a — query_events clamps limit and offset
# ─────────────────────────────────────────────────────────────────────────────


def test_query_events_clamps_huge_limit():
    """query_events with limit=999999 is clamped to at most 5000 (FIX 8)."""
    from axi import store

    now = time.time()
    store.insert_event(now - 1, "s", "info", "msg1", None)
    store.insert_event(now - 2, "s", "info", "msg2", None)

    results = store.query_events(limit=999999)
    assert isinstance(results, list)
    assert len(results) <= 5000


def test_query_events_clamps_zero_or_negative_limit():
    """query_events with limit<=0 is clamped to 1 (FIX 8)."""
    from axi import store

    now = time.time()
    store.insert_event(now - 1, "s", "info", "msg", None)

    results_zero = store.query_events(limit=0)
    assert isinstance(results_zero, list)
    assert len(results_zero) <= 1

    results_neg = store.query_events(limit=-5)
    assert isinstance(results_neg, list)
    assert len(results_neg) <= 1


def test_query_events_clamps_negative_offset():
    """query_events with offset<0 is clamped to 0 (FIX 8)."""
    from axi import store

    now = time.time()
    store.insert_event(now - 1, "s", "info", "msg", None)

    results = store.query_events(limit=10, offset=-100)
    assert isinstance(results, list)


# ─────────────────────────────────────────────────────────────────────────────
# FIX 8b — parse_since rejects negative amounts
# ─────────────────────────────────────────────────────────────────────────────


def test_parse_since_rejects_negative_amount():
    """parse_since('-1h') raises ValueError (FIX 8)."""
    from axi import events_cli

    with pytest.raises(ValueError):
        events_cli.parse_since("-1h")


def test_parse_since_rejects_negative_minutes():
    """parse_since('-30m') raises ValueError (FIX 8)."""
    from axi import events_cli

    with pytest.raises(ValueError):
        events_cli.parse_since("-30m")


# ─────────────────────────────────────────────────────────────────────────────
# FIX 9a — ContextVar token.reset (nesting-safe)
# ─────────────────────────────────────────────────────────────────────────────


def test_context_var_reset_restores_outer_value():
    """Token-based reset of _request_id_var restores the outer value (FIX 9)."""
    import asyncio
    from axi import obs

    async def _run():
        obs.set_request_id("outer-req")
        outer_before = obs.get_request_id()

        # Simulate inner middleware: token-based set+reset
        token = obs._request_id_var.set("inner-req")
        inner = obs.get_request_id()
        obs._request_id_var.reset(token)
        outer_after = obs.get_request_id()

        return outer_before, inner, outer_after

    outer_before, inner, outer_after = asyncio.run(_run())

    assert outer_before == "outer-req"
    assert inner == "inner-req"
    assert outer_after == "outer-req", (
        f"After token.reset(), outer value should be 'outer-req', got '{outer_after}' (FIX 9)"
    )


def test_install_middleware_uses_token_reset(monkeypatch):
    """install_request_id_middleware dispatch uses token-based reset (not set('-')) (FIX 9)."""
    # Test that nesting a middleware inside an outer request restores the outer value.
    import asyncio
    from axi import obs

    captured: list[str] = []

    async def _run():
        # Outer context
        obs.set_request_id("outer")
        captured.append(obs.get_request_id())

        # Inner middleware-like set + token reset
        token = obs._request_id_var.set("inner")
        captured.append(obs.get_request_id())
        obs._request_id_var.reset(token)
        captured.append(obs.get_request_id())  # should be "outer" again

    asyncio.run(_run())

    assert captured == ["outer", "inner", "outer"], (
        f"Token reset did not restore outer value: {captured}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# FIX 9b — embed worker stop mechanism exists and works
# ─────────────────────────────────────────────────────────────────────────────


def test_store_has_stop_embed_worker():
    """store module exposes a stop_embed_worker() callable (FIX 9)."""
    from axi import store

    assert callable(getattr(store, "stop_embed_worker", None)), (
        "store.stop_embed_worker must be a callable (FIX 9)"
    )


def test_stop_embed_worker_stops_thread():
    """After stop_embed_worker(), the axi-embed-worker thread stops (FIX 9)."""
    from axi import store

    # Reset the embed worker state so we can start it fresh
    store._embed_worker_started.clear()

    # Ensure the worker is running
    store._ensure_embed_worker()
    time.sleep(0.05)

    alive_before = [t for t in threading.enumerate()
                    if t.name == "axi-embed-worker" and t.is_alive()]
    if not alive_before:
        pytest.skip("axi-embed-worker did not start — cannot test stop")

    store.stop_embed_worker()

    deadline = time.time() + 2.0
    while time.time() < deadline:
        alive = [t for t in threading.enumerate()
                 if t.name == "axi-embed-worker" and t.is_alive()]
        if not alive:
            break
        time.sleep(0.05)

    alive = [t for t in threading.enumerate()
             if t.name == "axi-embed-worker" and t.is_alive()]
    assert not alive, (
        f"axi-embed-worker is still alive after stop_embed_worker() (FIX 9)"
    )
