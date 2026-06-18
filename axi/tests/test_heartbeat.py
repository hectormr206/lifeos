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
    heartbeat._alerted.clear()
    yield
    heartbeat._revivals.clear()
    heartbeat._alerted.clear()


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


def test_game_brains_includes_llama_vt():
    """GAME_BRAINS must include 'llama-vt.service' so heartbeat never revives VT during game mode.

    Spec: Scenario 'Heartbeat does not revive VT during game mode' +
          Scenario 'Heartbeat revives VT outside game mode'.
    TDD 3.1 RED — will fail until GAME_BRAINS is extended (3.2 GREEN).
    """
    from axi import heartbeat

    assert "llama-vt.service" in heartbeat.GAME_BRAINS


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
    """Revivals outside the 3600s window are pruned; cap resets at exactly 3600s."""
    from axi import heartbeat

    svc = "axi-voice.service"

    # Record 3 revivals at t=0
    for _ in range(3):
        heartbeat.record_revival(svc, now=0.0)

    # At t=3600 exactly the window has expired → under cap again (boundary is inclusive)
    assert heartbeat.under_cap(svc, now=3600.0) is True


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

    list(heartbeat.run_cycle(now=0.0))  # consume generator

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

    list(heartbeat.run_cycle(now=0.0))  # consume generator

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

    list(heartbeat.run_cycle(now=0.0))  # consume generator

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

    list(heartbeat.run_cycle(now=0.0))  # consume generator

    for call in recorded:
        assert "reset-failed" not in call
        if len(call) > 2:
            assert call[2] != "start"


def test_run_cycle_yields_per_service(monkeypatch):
    """run_cycle yields once per watched service (generator contract)."""
    from axi import heartbeat

    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda argv, **kw: _sp_result("inactive\n", 1))
    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))

    services = heartbeat.watched_services(game_active=False)
    yields = list(heartbeat.run_cycle(now=0.0))
    assert len(yields) == len(services), (
        f"Expected {len(services)} yields, got {len(yields)}"
    )


def test_run_cycle_exception_stops_yields(monkeypatch):
    """If processing service N raises, yields for N and after are not emitted."""
    from axi import heartbeat

    services = heartbeat.watched_services(game_active=False)
    crash_on = services[2]  # third service

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            svc = argv[3]
            if svc == crash_on:
                raise RuntimeError("simulated subprocess hang")
            return _sp_result("inactive\n", 1)
        return _sp_result("", 0)

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))

    yields_before_crash = 0
    try:
        for _ in heartbeat.run_cycle(now=0.0):
            yields_before_crash += 1
    except RuntimeError:
        pass

    # Should have yielded for the 2 services processed before the crash
    assert yields_before_crash == 2, (
        f"Expected 2 yields before crash, got {yields_before_crash}"
    )


def test_main_beats_per_service(monkeypatch):
    """main() emits WATCHDOG=1 once per service in a clean cycle."""
    from axi import heartbeat

    services = heartbeat.watched_services(game_active=False)
    expected_beats = len(services)

    # run_cycle that yields len(services) times then exits main via SystemExit
    iteration = [0]

    def fake_run_cycle(now=None):
        for _ in services:
            yield
        iteration[0] += 1
        if iteration[0] >= 1:
            raise SystemExit(0)

    sd_calls = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: sd_calls.append(s))
    monkeypatch.setattr(heartbeat, "run_cycle", fake_run_cycle)
    monkeypatch.setattr(heartbeat.time, "sleep", lambda _: None)

    try:
        heartbeat.main()
    except SystemExit:
        pass

    watchdog_beats = sd_calls.count("WATCHDOG=1")
    assert watchdog_beats == expected_beats, (
        f"Expected {expected_beats} WATCHDOG=1 beats, got {watchdog_beats}"
    )


def test_main_no_beat_on_exception(monkeypatch):
    """When run_cycle raises on first service, WATCHDOG=1 is never emitted."""
    from axi import heartbeat

    def raising_run_cycle(now=None):
        raise RuntimeError("simulated stall")
        yield  # make it a generator that never yields

    sd_calls = []
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: sd_calls.append(s))
    monkeypatch.setattr(heartbeat, "run_cycle", raising_run_cycle)
    monkeypatch.setattr(heartbeat.time, "sleep", lambda _: None)

    # main() should propagate the exception (no swallow)
    try:
        heartbeat.main()
    except RuntimeError:
        pass
    except SystemExit:
        pass

    assert "WATCHDOG=1" not in sd_calls, (
        f"WATCHDOG=1 should not be emitted when run_cycle raises: {sd_calls}"
    )


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


def test_alert_cap_exceeded_deduplicated(monkeypatch):
    """notify-send fires once per cap-exceeded episode, not every cycle."""
    from axi import heartbeat

    svc = "axi-voice.service"
    # Pre-fill 3 revivals so cap is exceeded from the start
    for _ in range(3):
        heartbeat.record_revival(svc, now=0.0)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            s = argv[3]
            return _sp_result("failed\n" if s == svc else "inactive\n", 0)
        return _sp_result("", 0)

    sp_recorded: list[list[str]] = []

    def recording_run(argv, **kw):
        sp_recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    # Run cycle twice — notify-send must fire exactly once
    list(heartbeat.run_cycle(now=0.0))
    list(heartbeat.run_cycle(now=1.0))

    notify_calls = [a for a in sp_recorded if "notify-send" in a]
    assert len(notify_calls) == 1, (
        f"Expected notify-send once, got {len(notify_calls)} times"
    )


def test_alert_dedup_resets_on_recovery(monkeypatch):
    """After a capped service recovers, the alert guard resets so it fires again on next cap episode."""
    from axi import heartbeat

    svc = "axi-voice.service"
    for _ in range(3):
        heartbeat.record_revival(svc, now=0.0)

    is_failed_flag = [True]

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            s = argv[3]
            if s == svc:
                return _sp_result("failed\n" if is_failed_flag[0] else "inactive\n", 0)
            return _sp_result("inactive\n", 1)
        return _sp_result("", 0)

    sp_recorded: list[list[str]] = []

    def recording_run(argv, **kw):
        sp_recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    # Cycle 1: capped → alert fires
    list(heartbeat.run_cycle(now=0.0))
    notify_calls_1 = [a for a in sp_recorded if "notify-send" in a]
    assert len(notify_calls_1) == 1

    # Service recovers: is-failed returns inactive
    is_failed_flag[0] = False
    sp_recorded.clear()
    list(heartbeat.run_cycle(now=1.0))  # recovery cycle

    # Service fails again with fresh window (different svc to avoid reusing old state)
    # Reset revivals manually and make it fail + capped again
    is_failed_flag[0] = True
    heartbeat._revivals.clear()
    for _ in range(3):
        heartbeat.record_revival(svc, now=5000.0)
    sp_recorded.clear()
    list(heartbeat.run_cycle(now=5001.0))

    notify_calls_2 = [a for a in sp_recorded if "notify-send" in a]
    assert len(notify_calls_2) == 1, (
        "Expected alert to fire again after recovery; alert guard not reset"
    )


def test_game_mode_lock_midcycle_blocks_brain_revival(monkeypatch, tmp_path):
    """Game-mode lock appearing mid-cycle prevents GAME_BRAIN revival.

    game_mode_active() returns False at cycle start (so brains are watched),
    then True when re-checked immediately before reviving a brain service.
    The brain must NOT be revived.
    """
    from axi import heartbeat

    lock = tmp_path / "game-mode.lock"
    # Lock does NOT exist at cycle start → brains are included in watchlist
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)

    brain_svc = heartbeat.GAME_BRAINS[0]  # llama-server.service
    core_svc = heartbeat.HEARTBEAT_SERVICES[0]  # axi-voice.service

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            # Both core and brain service are failed
            return _sp_result("failed\n", 0)
        return _sp_result("", 0)

    sp_recorded: list[list[str]] = []

    def recording_run(argv, **kw):
        sp_recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    # Game-mode lock appears after cycle starts (mid-cycle) — simulate by
    # creating the lock file so it exists when brain is about to be processed.
    # We do this by patching is_failed to create the lock right before the brain call.
    original_is_failed = heartbeat.is_failed
    call_count = [0]

    def side_effecting_is_failed(svc):
        result = original_is_failed(svc)
        call_count[0] += 1
        # After processing all core services, game starts → lock appears
        if call_count[0] >= len(heartbeat.HEARTBEAT_SERVICES):
            lock.touch()
        return result

    monkeypatch.setattr(heartbeat, "is_failed", side_effecting_is_failed)

    list(heartbeat.run_cycle(now=0.0))

    revive_calls = [a for a in sp_recorded if "reset-failed" in a or
                    (len(a) > 2 and a[2] == "start")]
    revived_svcs = {a[-1] for a in revive_calls}

    assert brain_svc not in revived_svcs, (
        f"{brain_svc} was revived despite game-mode lock appearing mid-cycle"
    )
    # Core service should still have been revived (it was processed before lock appeared)
    assert core_svc in revived_svcs, (
        f"{core_svc} should have been revived (processed before game lock)"
    )


# ===========================================================================
# Phase 5 — Unit file parse test
# ===========================================================================

# ===========================================================================
# Phase 6 — FIX 2: llama-vt revival guard (triad-active only)
# ===========================================================================

def test_vt_revival_skipped_when_triad_inactive(monkeypatch):
    """llama-vt.service in failed state + 35B active (triad inactive) → NOT revived.

    FIX 2 RED: will fail until run_cycle guards llama-vt revival with is_triad_active().
    """
    from axi import heartbeat, models_manager

    # Game mode OFF → brains are watched
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    # Triad inactive: primary is NOT qwen35-4b
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: False)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            svc = argv[3]
            return _sp_result("failed\n" if svc == "llama-vt.service" else "inactive\n", 0)
        return _sp_result("", 0)

    recorded = []

    def recording_run(argv, **kw):
        recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=0.0))

    revive_calls = [a for a in recorded if "reset-failed" in a or
                    (len(a) > 2 and a[2] == "start")]
    revived = {a[-1] for a in revive_calls}
    assert "llama-vt.service" not in revived, (
        "llama-vt.service was revived despite triad being inactive (35B active)"
    )


def test_vt_revival_happens_when_triad_active(monkeypatch):
    """llama-vt.service in failed state + triad active (primary==4B) → revived.

    FIX 2 GREEN guard: revival proceeds when is_triad_active() is True.
    """
    from axi import heartbeat, models_manager

    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(models_manager, "is_triad_active", lambda: True)

    def fake_run(argv, **kw):
        if argv[:3] == ["systemctl", "--user", "is-failed"]:
            svc = argv[3]
            return _sp_result("failed\n" if svc == "llama-vt.service" else "inactive\n", 0)
        return _sp_result("", 0)

    recorded = []

    def recording_run(argv, **kw):
        recorded.append(argv)
        return fake_run(argv, **kw)

    monkeypatch.setattr(heartbeat.subprocess, "run", recording_run)
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=0.0))

    revive_calls = [a for a in recorded if "reset-failed" in a]
    revived = {a[-1] for a in revive_calls}
    assert "llama-vt.service" in revived, (
        "llama-vt.service should be revived when triad is active (primary==4B)"
    )


def test_unit_file_has_required_properties():
    """axi-heartbeat.service must contain all four self-protection properties."""
    unit_path = Path(__file__).parent.parent / "systemd" / "axi-heartbeat.service"
    text = unit_path.read_text()

    assert "Type=notify" in text
    assert "Restart=always" in text
    assert "StartLimitIntervalSec=0" in text
    assert "WatchdogSec=90" in text
    assert "NotifyAccess=main" in text
