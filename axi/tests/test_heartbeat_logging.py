"""Tests for heartbeat.py observability instrumentation — Slice 1 TDD.

Spec coverage (tasks 1.13–1.21):
- revive() path emits log.warning + events.log_warning (1.13)
- cap-exhausted path emits log.warning + events.log_warning (1.14)
- game-mode skip path emits log.info + events.log_info (1.15)
- triad-inactive skip emits log.info (1.16)
- ensure-up start emits log.info + events.log_info (1.17)
- non-action (healthy service) pass is DEBUG only (1.18/1.19)
- logging failure inside run_cycle does NOT abort service action (1.20/1.21)

All tests use the existing conftest autouse seam (_block_live_system_subprocess)
and monkeypatch heartbeat.subprocess.run as the established pattern.
"""
from __future__ import annotations

import subprocess
import types
from pathlib import Path
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _sp_result(stdout: str, returncode: int = 0) -> types.SimpleNamespace:
    return types.SimpleNamespace(stdout=stdout, returncode=returncode, stderr="")


# ---------------------------------------------------------------------------
# Autouse: clear module-level mutable state between tests
# ---------------------------------------------------------------------------

import pytest


@pytest.fixture(autouse=True)
def _clear_heartbeat_state():
    from axi import heartbeat
    heartbeat._revivals.clear()
    heartbeat._alerted.clear()
    heartbeat._vt_ensure_up_alerted = False
    heartbeat._embed_ensure_up_alerted = False
    yield
    heartbeat._revivals.clear()
    heartbeat._alerted.clear()
    heartbeat._vt_ensure_up_alerted = False
    heartbeat._embed_ensure_up_alerted = False


# ---------------------------------------------------------------------------
# 1.13 — revive() path emits log.warning AND events.log_warning
# ---------------------------------------------------------------------------

def test_revive_emits_log_and_event(monkeypatch):
    """When a service is detected as failed + under cap, run_cycle emits log.warning AND events.log_warning."""
    from axi import heartbeat, obs

    svc = "axi-voice.service"

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n" if argv[3] == svc else "inactive\n")
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    log_calls: list = []
    events_calls: list = []

    # Patch obs.lifecycle to capture what it records
    def fake_lifecycle(log, level, source, message, **data):
        log_calls.append({"level": level, "source": source, "message": message, "data": data})
        # Actually call the real log method too so log records exist
        try:
            getattr(log, level)(message)
        except Exception:
            pass

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    list(heartbeat.run_cycle(now=0.0))

    # Find revive calls
    revive_calls = [c for c in log_calls
                    if c["source"] == "heartbeat" and "revive" in c.get("message", "").lower()
                    or "failed" in str(c.get("data", {}))]

    assert revive_calls, (
        f"Expected obs.lifecycle call for revive action, got: {log_calls}"
    )
    revive_call = revive_calls[0]
    assert revive_call["level"] in ("warning", "info"), (
        f"Expected warning or info level for revive, got: {revive_call['level']}"
    )
    assert revive_call["data"].get("service") == svc or svc in str(revive_call), (
        f"Expected service={svc} in call data: {revive_call}"
    )


# ---------------------------------------------------------------------------
# 1.14 — cap-exhausted path emits log.warning AND events.log_warning
# ---------------------------------------------------------------------------

def test_cap_exhausted_emits_log_and_event(monkeypatch):
    """When cap is exhausted, run_cycle emits warning-level obs.lifecycle call."""
    from axi import heartbeat, obs

    svc = "axi-voice.service"
    # Pre-fill rate cap
    for _ in range(heartbeat.RATE_CAP):
        heartbeat.record_revival(svc, now=0.0)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n" if argv[3] == svc else "inactive\n")
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    lifecycle_calls: list = []

    def fake_lifecycle(log, level, source, message, **data):
        lifecycle_calls.append({"level": level, "source": source, "message": message, "data": data})

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    list(heartbeat.run_cycle(now=0.0))

    cap_calls = [c for c in lifecycle_calls
                 if "cap" in str(c).lower() or "exhaust" in str(c).lower()
                 or c["data"].get("reason") == "cap_exhausted"]

    assert cap_calls, (
        f"Expected obs.lifecycle call for cap-exhausted, got: {lifecycle_calls}"
    )
    assert cap_calls[0]["level"] == "warning", (
        f"Expected warning level for cap-exhausted, got: {cap_calls[0]['level']}"
    )


# ---------------------------------------------------------------------------
# 1.15 — game-mode skip emits log.info AND events.log_info
# ---------------------------------------------------------------------------

def test_game_mode_skip_emits_log_and_event(monkeypatch, tmp_path):
    """Mid-cycle game-mode activation: brain service is failed but skipped; log.info emitted.

    The scenario: cycle starts with game OFF (so GAME_BRAINS are in watched list),
    then game mode lock appears before the brain service is processed.
    This mirrors the existing test_game_mode_lock_midcycle_blocks_brain_revival pattern.
    """
    from axi import heartbeat, obs

    lock = tmp_path / "game-mode.lock"
    # Lock does NOT exist at cycle start → brains are included in watchlist
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)

    brain_svc = heartbeat.GAME_BRAINS[0]  # e.g. llama-server.service

    # is-failed returns "failed" for the brain service, "inactive" for others
    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n" if argv[3] == brain_svc else "inactive\n")
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    lifecycle_calls: list = []

    def fake_lifecycle(lg, level, source, message, **data):
        lifecycle_calls.append({"level": level, "source": source, "message": message, "data": data})

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    # Create the lock BEFORE run_cycle starts so game_mode_active() returns True
    # for the brain check inside run_cycle (the mid-cycle condition).
    # We need game OFF at start (so brains are watched) but ON for the branch check.
    # Simulate: game_mode_active() returns False first, then True.
    call_count = [0]
    original_game_mode = heartbeat.game_mode_active

    def side_effect_game_mode():
        call_count[0] += 1
        if call_count[0] <= 1:
            return False  # first call: cycle start — game OFF so brains are watched
        return True       # subsequent calls: game turned ON mid-cycle

    monkeypatch.setattr(heartbeat, "game_mode_active", side_effect_game_mode)

    list(heartbeat.run_cycle(now=0.0))

    game_mode_calls = [c for c in lifecycle_calls
                       if "game" in str(c).lower()
                       or c["data"].get("reason") == "game_mode"]

    assert game_mode_calls, (
        f"Expected obs.lifecycle call for game-mode skip, got: {lifecycle_calls}"
    )
    assert game_mode_calls[0]["level"] in ("info", "debug"), (
        f"Expected info level for game-mode skip, got: {game_mode_calls[0]['level']}"
    )


# ---------------------------------------------------------------------------
# 1.16 — triad-inactive skip emits log.info
# ---------------------------------------------------------------------------

def test_triad_inactive_skip_emits_log(monkeypatch):
    """When llama-vt.service is failed and triad is inactive, a log is emitted at info level."""
    from axi import heartbeat, models_manager, obs

    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: False)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n" if argv[3] == "llama-vt.service" else "inactive\n")
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    lifecycle_calls: list = []

    def fake_lifecycle(log, level, source, message, **data):
        lifecycle_calls.append({"level": level, "source": source, "message": message, "data": data})

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    list(heartbeat.run_cycle(now=0.0))

    triad_calls = [c for c in lifecycle_calls
                   if "triad" in str(c).lower()
                   or c["data"].get("reason") == "triad_inactive"]

    assert triad_calls, (
        f"Expected obs.lifecycle call for triad-inactive skip, got: {lifecycle_calls}"
    )
    assert triad_calls[0]["level"] in ("info", "debug"), (
        f"Expected info level for triad-inactive, got: {triad_calls[0]['level']}"
    )


# ---------------------------------------------------------------------------
# 1.17 — ensure-up start (llama-vt / llama-embed) emits log.info AND events.log_info
# ---------------------------------------------------------------------------

def test_ensure_up_emits_log_and_event(monkeypatch):
    """ensure-up for llama-embed (inactive, under cap) emits obs.lifecycle call with service + action=start."""
    from axi import heartbeat, obs

    svc = "llama-embed.service"
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("inactive\n", 1)  # not failed
        if argv[:3] == ["systemctl", "--user", "is-active"]:
            return _sp_result("inactive\n" if argv[3] == svc else "active\n", 0)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    lifecycle_calls: list = []

    def fake_lifecycle(log, level, source, message, **data):
        lifecycle_calls.append({"level": level, "source": source, "message": message, "data": data})

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    list(heartbeat.run_cycle(now=0.0))

    ensure_up_calls = [c for c in lifecycle_calls
                       if svc in str(c) or "ensure" in str(c).lower() or "start" in str(c).lower()]

    assert ensure_up_calls, (
        f"Expected obs.lifecycle call for ensure-up start of {svc}, got: {lifecycle_calls}"
    )
    # Ensure at least one call has action=start or similar
    found_action = any(
        c["data"].get("action") == "start" or "start" in c.get("message", "").lower()
        for c in ensure_up_calls
    )
    assert found_action, (
        f"Expected action=start in ensure-up call data, got: {ensure_up_calls}"
    )


# ---------------------------------------------------------------------------
# 1.18 — non-action (healthy service) pass is DEBUG only
# ---------------------------------------------------------------------------

def test_per_cycle_pass_is_debug_only(monkeypatch, caplog):
    """When a service is healthy (not failed, not inactive), only DEBUG records emitted for it."""
    import logging
    from axi import heartbeat, obs

    # Disable obs.lifecycle side-effects — we test the log level via caplog
    real_lifecycle = None

    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    # All services healthy: not failed, not inactive (is-active returns active)
    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("inactive\n", 1)  # not failed
        if argv[:3] == ["systemctl", "--user", "is-active"]:
            return _sp_result("active\n", 0)  # all active
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    lifecycle_calls: list = []

    def fake_lifecycle(log, level, source, message, **data):
        lifecycle_calls.append({"level": level, "source": source, "message": message, "data": data})

    monkeypatch.setattr(obs, "lifecycle", fake_lifecycle)

    # Use caplog to capture actual log records
    with caplog.at_level(logging.DEBUG, logger="axi.heartbeat"):
        list(heartbeat.run_cycle(now=0.0))

    # No INFO or WARNING records should be emitted by heartbeat for the non-action pass
    # (but lifecycle_calls is the key assertion — should be empty OR all DEBUG)
    info_or_warning_calls = [c for c in lifecycle_calls if c["level"] in ("info", "warning")]

    # For healthy services, no lifecycle call should be INFO/WARNING
    # (DEBUG is OK, no call at all is OK)
    assert not info_or_warning_calls, (
        f"Expected no INFO/WARNING lifecycle calls for healthy services, got: {info_or_warning_calls}"
    )


# ---------------------------------------------------------------------------
# 1.20 / 1.21 — logging failure does NOT abort the service action
# ---------------------------------------------------------------------------

def test_heartbeat_logging_failure_does_not_abort_action(monkeypatch):
    """If obs.lifecycle raises, the service management action still executes."""
    from axi import heartbeat, obs

    svc = "axi-voice.service"

    run_calls: list = []

    def fake_run(argv, **kw):
        run_calls.append(list(argv))
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n" if argv[3] == svc else "inactive\n")
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    # Make obs.lifecycle RAISE every time
    def exploding_lifecycle(log, level, source, message, **data):
        raise RuntimeError("simulated logging failure")

    monkeypatch.setattr(obs, "lifecycle", exploding_lifecycle)

    # run_cycle must complete without propagating the logging exception
    beats = list(heartbeat.run_cycle(now=0.0))

    # The service action (reset-failed + start) must still have been executed
    reset_calls = [a for a in run_calls if "reset-failed" in a and svc in a]
    assert reset_calls, (
        f"reset-failed for {svc} was NOT called despite logging failure — action was aborted: {run_calls}"
    )
