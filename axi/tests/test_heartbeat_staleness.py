"""Tests for the heartbeat staleness guard — Layer 2: the safety net for
services that keep running STALE code (older than the current git HEAD) while
days pass without a redeploy.

Strict TDD. No real systemctl/git/DB is ever invoked — all side-effects are
injected via monkeypatch, matching the existing heartbeat test style.

CRITICAL: the guard aligns running services to HEAD only (authorized/committed
code). It never checks out, merges, or deploys any dev-env worktree or branch.
"""
from __future__ import annotations

import time
import types
from pathlib import Path

import pytest


def _sp_result(stdout: str = "", returncode: int = 0):
    return types.SimpleNamespace(stdout=stdout, returncode=returncode)


@pytest.fixture(autouse=True)
def clear_revivals():
    from axi import heartbeat
    heartbeat._revivals.clear()
    heartbeat._alerted.clear()
    yield
    heartbeat._revivals.clear()
    heartbeat._alerted.clear()


# ===========================================================================
# Pure function: is_stale
# ===========================================================================

def test_is_stale_true_when_started_before_head():
    from axi import heartbeat
    assert heartbeat.is_stale(
        "axi-dashboard.service", active_enter_ts=100.0, head_commit_ts=200.0
    ) is True


def test_is_stale_false_when_started_after_head():
    from axi import heartbeat
    assert heartbeat.is_stale(
        "axi-dashboard.service", active_enter_ts=300.0, head_commit_ts=200.0
    ) is False


def test_is_stale_false_when_started_exactly_at_head():
    """Boundary: started at the same instant as the commit → NOT stale."""
    from axi import heartbeat
    assert heartbeat.is_stale(
        "axi-dashboard.service", active_enter_ts=200.0, head_commit_ts=200.0
    ) is False


def test_is_stale_false_when_start_time_unknown():
    """Unknown start time (None) → not provably stale → do NOT restart."""
    from axi import heartbeat
    assert heartbeat.is_stale(
        "axi-dashboard.service", active_enter_ts=None, head_commit_ts=200.0
    ) is False


# ===========================================================================
# Pure function: stale_restart_decision (policy)
# ===========================================================================

def test_decision_dashboard_stale_restarts_immediately():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-dashboard.service",
        stale=True, game_active=False, under_cap=True, voice_busy=False,
    ) == "restart"


def test_decision_voice_stale_and_busy_defers():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-voice.service",
        stale=True, game_active=False, under_cap=True, voice_busy=True,
    ) == "defer_busy"


def test_decision_voice_stale_and_idle_restarts():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-voice.service",
        stale=True, game_active=False, under_cap=True, voice_busy=False,
    ) == "restart"


def test_decision_game_mode_skips_even_if_stale():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-dashboard.service",
        stale=True, game_active=True, under_cap=True, voice_busy=False,
    ) == "skip_game"


def test_decision_rate_capped_skips():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-dashboard.service",
        stale=True, game_active=False, under_cap=False, voice_busy=False,
    ) == "skip_capped"


def test_decision_fresh_is_noop():
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-dashboard.service",
        stale=False, game_active=False, under_cap=True, voice_busy=False,
    ) == "skip_fresh"


def test_decision_busy_only_affects_busy_sensitive_services():
    """A busy signal must NOT block a stateless service like the dashboard."""
    from axi import heartbeat
    assert heartbeat.stale_restart_decision(
        "axi-dashboard.service",
        stale=True, game_active=False, under_cap=True, voice_busy=True,
    ) == "restart"


# ===========================================================================
# Impure gatherers (injected subprocess.run)
# ===========================================================================

def test_head_src_commit_ts_parses_epoch(monkeypatch):
    from axi import heartbeat

    recorded = []

    def fake_run(argv, **kw):
        recorded.append(argv)
        return _sp_result("1784662941\n")

    monkeypatch.setattr(heartbeat.subprocess, "run", fake_run)
    ts = heartbeat.head_src_commit_ts()
    assert ts == 1784662941.0
    # Must scope the log to the axi/src/axi tree ONLY (doc/mobile commits ignored).
    argv = recorded[0]
    assert "git" in argv and "log" in argv
    assert "axi/src/axi" in argv
    assert "--format=%ct" in argv


def test_head_src_commit_ts_none_on_empty(monkeypatch):
    from axi import heartbeat
    monkeypatch.setattr(heartbeat.subprocess, "run", lambda a, **kw: _sp_result(""))
    assert heartbeat.head_src_commit_ts() is None


def test_head_src_commit_ts_none_on_garbage(monkeypatch):
    from axi import heartbeat
    monkeypatch.setattr(heartbeat.subprocess, "run", lambda a, **kw: _sp_result("nope"))
    assert heartbeat.head_src_commit_ts() is None


def test_service_active_enter_ts_parses_systemd_timestamp(monkeypatch):
    from axi import heartbeat

    monkeypatch.setattr(
        heartbeat.subprocess, "run",
        lambda a, **kw: _sp_result("Wed 2026-07-22 07:15:02 CST\n"),
    )
    ts = heartbeat.service_active_enter_ts("axi-dashboard.service")
    import datetime as _dt
    expected = time.mktime(
        _dt.datetime(2026, 7, 22, 7, 15, 2).timetuple()
    )
    assert ts == expected


def test_service_active_enter_ts_none_when_never_active(monkeypatch):
    from axi import heartbeat
    monkeypatch.setattr(heartbeat.subprocess, "run", lambda a, **kw: _sp_result("\n"))
    assert heartbeat.service_active_enter_ts("axi-dashboard.service") is None


def test_is_voice_busy_reflects_meeting_in_progress(monkeypatch):
    from axi import heartbeat, store
    monkeypatch.setattr(store, "meeting_in_progress", lambda: True)
    assert heartbeat.is_voice_busy() is True
    monkeypatch.setattr(store, "meeting_in_progress", lambda: False)
    assert heartbeat.is_voice_busy() is False


def test_is_voice_busy_fail_safe_true_on_error(monkeypatch):
    from axi import heartbeat, store

    def boom():
        raise RuntimeError("db down")

    monkeypatch.setattr(store, "meeting_in_progress", boom)
    assert heartbeat.is_voice_busy() is True  # uncertain → defer


# ===========================================================================
# Integration inside run_cycle
# ===========================================================================

def _no_failed_run(argv, **kw):
    """systemctl fake: nothing failed, everything active."""
    if argv[:3] == ["systemctl", "--user", "is-failed"]:
        return _sp_result("inactive\n", 1)
    if argv[:3] == ["systemctl", "--user", "is-active"]:
        return _sp_result("active\n", 0)
    return _sp_result("", 0)


def test_run_cycle_restarts_stale_dashboard(monkeypatch):
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: 1000.0)
    # dashboard started BEFORE the last src commit → stale; others fresh.
    monkeypatch.setattr(
        heartbeat, "service_active_enter_ts",
        lambda svc: 500.0 if svc == "axi-dashboard.service" else 2000.0,
    )
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: False)

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded
                if a[:3] == ["systemctl", "--user", "restart"]]
    restarted = {a[-1] for a in restarts}
    assert "axi-dashboard.service" in restarted
    assert "axi-voice.service" not in restarted  # fresh


def test_run_cycle_defers_stale_voice_when_busy(monkeypatch):
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: 1000.0)
    monkeypatch.setattr(heartbeat, "service_active_enter_ts", lambda svc: 500.0)  # all stale
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: True)  # conversation active

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded if a[:3] == ["systemctl", "--user", "restart"]]
    restarted = {a[-1] for a in restarts}
    assert "axi-voice.service" not in restarted, "voice must be deferred while busy"


def test_run_cycle_restarts_stale_voice_when_idle(monkeypatch):
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: 1000.0)
    monkeypatch.setattr(heartbeat, "service_active_enter_ts", lambda svc: 500.0)
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: False)

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded if a[:3] == ["systemctl", "--user", "restart"]]
    restarted = {a[-1] for a in restarts}
    assert "axi-voice.service" in restarted


def test_run_cycle_skips_stale_restart_in_game_mode(monkeypatch, tmp_path):
    from axi import heartbeat

    lock = tmp_path / "game-mode.lock"
    lock.touch()
    monkeypatch.setattr(heartbeat, "_game_lock_path", lambda: lock)
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: 1000.0)
    monkeypatch.setattr(heartbeat, "service_active_enter_ts", lambda svc: 500.0)
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: False)

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded if a[:3] == ["systemctl", "--user", "restart"]]
    assert restarts == [], "no stale restarts during game mode"


def test_run_cycle_skips_stale_restart_when_capped(monkeypatch):
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: 1000.0)
    monkeypatch.setattr(heartbeat, "service_active_enter_ts", lambda svc: 500.0)
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: False)
    # Exhaust the cap for dashboard
    for _ in range(heartbeat.RATE_CAP):
        heartbeat.record_revival("axi-dashboard.service", now=1.0)

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded if a[:3] == ["systemctl", "--user", "restart"]
                and a[-1] == "axi-dashboard.service"]
    assert restarts == [], "capped service must not be restarted (thrash guard)"


def test_run_cycle_no_stale_restart_when_head_unknown(monkeypatch):
    """If HEAD src commit time can't be determined, restart nothing (fail-safe)."""
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))
    monkeypatch.setattr(heartbeat, "head_src_commit_ts", lambda: None)
    monkeypatch.setattr(heartbeat, "service_active_enter_ts", lambda svc: 500.0)
    monkeypatch.setattr(heartbeat, "is_voice_busy", lambda: False)

    recorded = []
    monkeypatch.setattr(heartbeat.subprocess, "run",
                        lambda a, **kw: recorded.append(a) or _no_failed_run(a, **kw))
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    list(heartbeat.run_cycle(now=1.0))

    restarts = [a for a in recorded if a[:3] == ["systemctl", "--user", "restart"]]
    assert restarts == []


def test_freshness_enforcement_never_aborts_cycle(monkeypatch):
    """A failure inside freshness enforcement must NOT stop the watchdog beats."""
    from axi import heartbeat

    monkeypatch.setattr(heartbeat, "_game_lock_path",
                        lambda: Path("/nonexistent/game-mode.lock"))

    def boom():
        raise RuntimeError("git exploded")

    monkeypatch.setattr(heartbeat, "head_src_commit_ts", boom)
    monkeypatch.setattr(heartbeat.subprocess, "run", _no_failed_run)
    monkeypatch.setattr(heartbeat, "_sd_notify", lambda s: None)

    services = heartbeat.watched_services(game_active=False)
    yields = list(heartbeat.run_cycle(now=1.0))
    assert len(yields) == len(services), "freshness failure must not stop beats"
