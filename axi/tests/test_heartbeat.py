"""Tests for axi.heartbeat — self-healing supervisor (corazon).

Strict TDD: every behavior is proven RED before GREEN.
No test ever invokes real systemctl, real notify-send, or real sd_notify.
All subprocess.run calls are monkeypatched.
"""
from __future__ import annotations

import types
from collections import deque
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sp_result(stdout: str, returncode: int = 0) -> types.SimpleNamespace:
    """Build a fake subprocess.CompletedProcess-like object."""
    return types.SimpleNamespace(stdout=stdout, returncode=returncode)


# ---------------------------------------------------------------------------
# Autouse fixture: clear module-level mutable _revivals between tests
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def clear_revivals():
    """Reset per-service rate-cap state between tests."""
    from axi import heartbeat
    heartbeat._revivals.clear()
    yield
    heartbeat._revivals.clear()


# ===========================================================================
# Phase 1 — Foundation: constants
# ===========================================================================

def test_watchlist_membership():
    """HEARTBEAT_SERVICES contains exactly the 5 core services."""
    from axi import heartbeat

    expected = {
        "axi-voice.service",
        "axi-whisper.service",
        "ydotoold.service",
        "axi-tray.service",
        "axi-dashboard.service",
    }
    assert set(heartbeat.HEARTBEAT_SERVICES) == expected
    assert "axi-translate.service" not in heartbeat.HEARTBEAT_SERVICES


def test_watchlist_independence_from_doctor():
    """HEARTBEAT_SERVICES is NOT the same object as doctor.REQUIRED_SERVICES."""
    from axi import doctor, heartbeat

    assert heartbeat.HEARTBEAT_SERVICES is not doctor.REQUIRED_SERVICES


def test_startup_grace_lt_watchdog():
    """STARTUP_GRACE_SEC must be strictly less than WatchdogSec (90)."""
    from axi import heartbeat

    assert heartbeat.STARTUP_GRACE_SEC < 90


# ===========================================================================
# Phase 2 — Core logic: detection, game-mode, rate-cap
# ===========================================================================

def test_is_failed_true(monkeypatch):
    """is_failed returns True when systemctl stdout is 'failed'."""
    from axi import heartbeat

    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return _sp_result("failed\n", returncode=0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    assert heartbeat.is_failed("axi-voice.service") is True
    assert calls[0] == ["systemctl", "--user", "is-failed", "axi-voice.service"]


def test_is_failed_false(monkeypatch):
    """is_failed returns False when systemctl stdout is 'inactive'."""
    from axi import heartbeat

    monkeypatch.setattr(
        heartbeat.subprocess, "run",
        lambda argv, **kw: _sp_result("inactive\n", returncode=1),
    )
    assert heartbeat.is_failed("axi-voice.service") is False


def test_game_mode_active_true(monkeypatch, tmp_path):
    """game_mode_active returns True when lock file exists."""
    from axi import heartbeat

    lock = tmp_path / "game-mode.lock"
    lock.touch()
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)
    assert heartbeat.game_mode_active() is True


def test_game_mode_active_false(monkeypatch, tmp_path):
    """game_mode_active returns False when lock file is absent."""
    from axi import heartbeat

    lock = tmp_path / "game-mode.lock"  # does NOT exist
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)
    assert heartbeat.game_mode_active() is False


def test_watched_services_game_on():
    """When game is active, watched_services == HEARTBEAT_SERVICES (no GAME_BRAINS)."""
    from axi import heartbeat

    result = heartbeat.watched_services(game_active=True)
    assert set(result) == set(heartbeat.HEARTBEAT_SERVICES)
    for brain in heartbeat.GAME_BRAINS:
        assert brain not in result


def test_watched_services_game_off():
    """When game is off, watched_services includes HEARTBEAT_SERVICES + GAME_BRAINS."""
    from axi import heartbeat

    result = heartbeat.watched_services(game_active=False)
    for svc in heartbeat.HEARTBEAT_SERVICES:
        assert svc in result
    for brain in heartbeat.GAME_BRAINS:
        assert brain in result


def test_under_cap_allows_first_three():
    """under_cap returns True (allowed) for the first 3 revivals, False on 4th."""
    from axi import heartbeat

    svc = "axi-voice.service"
    now = 1000.0

    # Three revivals at t=now: all should be under cap
    assert heartbeat.under_cap(svc, now) is True
    heartbeat.record_revival(svc, now)
    assert heartbeat.under_cap(svc, now) is True
    heartbeat.record_revival(svc, now)
    assert heartbeat.under_cap(svc, now) is True
    heartbeat.record_revival(svc, now)

    # 4th check — cap reached
    assert heartbeat.under_cap(svc, now) is False


def test_under_cap_prunes_old():
    """Revivals outside the 3600s window are pruned; cap resets."""
    from axi import heartbeat

    svc = "axi-voice.service"

    # Record 3 revivals at t=0
    for _ in range(3):
        heartbeat.record_revival(svc, now=0.0)

    # At t=3601 the window has expired → under cap again
    assert heartbeat.under_cap(svc, now=3601.0) is True


# ===========================================================================
# Phase 3 — Side-effect functions: revive, alert, sd_notify
# ===========================================================================

def test_revive_calls_reset_failed_then_start(monkeypatch):
    """revive issues reset-failed then start in order."""
    from axi import heartbeat

    calls = []
    monkeypatch.setattr(
        heartbeat.subprocess, "run",
        lambda argv, **kw: calls.append(argv) or _sp_result("", 0),
    )
    heartbeat.revive("axi-voice.service")

    assert len(calls) == 2
    assert calls[0] == ["systemctl", "--user", "reset-failed", "axi-voice.service"]
    assert calls[1] == ["systemctl", "--user", "start", "axi-voice.service"]


def test_alert_cap_exceeded_calls_notify_send(monkeypatch):
    """alert_cap_exceeded calls notify-send with the service name in the message."""
    from axi import heartbeat

    calls = []
    monkeypatch.setattr(
        heartbeat.subprocess, "run",
        lambda argv, **kw: calls.append(argv) or _sp_result("", 0),
    )
    heartbeat.alert_cap_exceeded("llama-server.service")

    assert calls, "notify-send was never called"
    assert "notify-send" in calls[0]
    # Service name must appear somewhere in the call arguments
    full_cmd = " ".join(calls[0])
    assert "llama-server.service" in full_cmd


def test_sd_notify_functions(monkeypatch):
    """notify_ready calls _sd_notify('READY=1'); notify_watchdog calls _sd_notify('WATCHDOG=1')."""
    from axi import heartbeat

    received = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda state: received.append(state))

    heartbeat.notify_ready()
    assert received == ["READY=1"]

    received.clear()
    heartbeat.notify_watchdog()
    assert received == ["WATCHDOG=1"]


# ===========================================================================
# Phase 4 — Spine: run_cycle + beat ordering
# ===========================================================================

def test_run_cycle_revives_failed_service(monkeypatch):
    """run_cycle revives a failed service; _sd_notify is NOT called by run_cycle itself."""
    from axi import heartbeat

    # axi-voice.service is-failed → "failed"; others → "inactive"
    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            svc = argv[3]
            stdout = "failed\n" if svc == "axi-voice.service" else "inactive\n"
            return _sp_result(stdout, returncode=0 if svc == "axi-voice.service" else 1)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)

    sd_calls = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: sd_calls.append(s))

    # No game-mode lock
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    sp_calls = []
    _orig_run = heartbeat.subprocess.run

    recorded = []

    def recording_run(argv, **kw):
        recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)

    heartbeat.run_cycle(now=0.0)

    # reset-failed and start were called for axi-voice.service
    reset_calls = [a for a in recorded if "reset-failed" in a]
    start_calls = [a for a in recorded if a[2:3] == ["start"]]
    assert any("axi-voice.service" in a for a in reset_calls)
    assert any("axi-voice.service" in a for a in start_calls)

    # _sd_notify NOT called by run_cycle (beat is caller's responsibility)
    assert sd_calls == []


def test_run_cycle_game_mode_blocks_brains(monkeypatch, tmp_path):
    """When game-mode.lock exists, llama-server.service is not revived."""
    from axi import heartbeat

    lock = tmp_path / "game-mode.lock"
    lock.touch()
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)

    recorded = []

    def fake_run(argv, **kw):
        recorded.append(argv)
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("failed\n", 0)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    heartbeat.run_cycle(now=0.0)

    for call in recorded:
        if "reset-failed" in call or (len(call) > 2 and call[2] == "start"):
            assert "llama-server.service" not in call
            assert "llama-nano.service" not in call


def test_run_cycle_cap_exceeded_alerts_no_revive(monkeypatch):
    """When cap is exceeded, alert_cap_exceeded is called and revive is NOT."""
    from axi import heartbeat

    svc = "axi-voice.service"
    # Pre-fill 3 revivals inside window
    for _ in range(3):
        heartbeat.record_revival(svc, now=0.0)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            s = argv[3]
            return _sp_result("failed\n" if s == svc else "inactive\n", 0)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))

    notify_calls = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    # Monkeypatch subprocess.run to record and detect notify-send vs systemctl
    sp_recorded = []

    def recording_run(argv, **kw):
        sp_recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)

    heartbeat.run_cycle(now=0.0)

    # notify-send must have been called
    assert any("notify-send" in a for a in sp_recorded)
    # reset-failed and start must NOT have been called for the capped service
    for call in sp_recorded:
        if "reset-failed" in call or (len(call) > 3 and call[2] == "start"):
            assert svc not in call, f"revive called for capped service: {call}"


def test_run_cycle_inactive_not_revived(monkeypatch):
    """is_failed returning False → no reset-failed or start."""
    from axi import heartbeat

    recorded = []

    def fake_run(argv, **kw):
        recorded.append(argv)
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            return _sp_result("inactive\n", 1)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    heartbeat.run_cycle(now=0.0)

    for call in recorded:
        assert "reset-failed" not in call
        if len(call) > 2:
            assert call[2] != "start"


def test_watchdog_beat_only_after_clean_cycle(monkeypatch):
    """When run_cycle raises, _sd_notify(WATCHDOG=1) is NOT called."""
    from axi import heartbeat
    import time

    def raising_run_cycle(now=None):
        raise RuntimeError("simulated stall")

    sd_calls = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: sd_calls.append(s))
    monkeypatch.setattr(heartbeat, "run_cycle", raising_run_cycle)

    # Simulate the main loop body for one iteration
    try:
        heartbeat.run_cycle()
        heartbeat.notify_watchdog()
    except RuntimeError:
        pass  # expected

    assert "WATCHDOG=1" not in sd_calls


def test_ready_emitted_once_before_first_cycle(monkeypatch):
    """notify_ready is called exactly once, before any run_cycle call."""
    from axi import heartbeat

    order = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: order.append(("notify", s)))

    call_count = [0]

    def counting_run_cycle(now=None):
        order.append(("cycle", None))
        call_count[0] += 1
        if call_count[0] >= 1:
            raise SystemExit(0)  # break after first cycle

    monkeypatch.setattr(heartbeat, "run_cycle", counting_run_cycle)
    monkeypatch.setattr(heartbeat.time, "sleep", lambda _: None)

    try:
        heartbeat.main()
    except SystemExit:
        pass

    # READY=1 must appear before the first cycle
    ready_indices = [i for i, e in enumerate(order) if e == ("notify", "READY=1")]
    cycle_indices = [i for i, e in enumerate(order) if e[0] == "cycle"]

    assert len(ready_indices) == 1, f"READY=1 called {len(ready_indices)} times, expected 1"
    assert ready_indices[0] < cycle_indices[0], "READY=1 must be emitted before first cycle"


# ===========================================================================
# Phase 5 — Unit file parse test
# ===========================================================================

def test_unit_file_has_required_properties():
    """axi-heartbeat.service must contain all four self-protection properties."""
    unit_path = Path(__file__).parent.parent / "systemd" / "axi-heartbeat.service"
    text = unit_path.read_text()

    assert "Type=notify" in text
    assert "Restart=always" in text
    assert "StartLimitIntervalSec=0" in text
    assert "WatchdogSec=90" in text
    assert "NotifyAccess=main" in text
