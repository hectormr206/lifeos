"""Tests for axi.redeploy — Layer 1: the deploy actually restarts code-serving services.

Strict TDD. No real service is ever restarted; subprocess.run is injected.
axi-redeploy must ONLY restart already-updated services: no DB, no git, no deploy.
"""
from __future__ import annotations

import types


def _sp_result(stdout: str = "", returncode: int = 0):
    return types.SimpleNamespace(stdout=stdout, returncode=returncode)


# ---------------------------------------------------------------------------
# restart_plan — the ordered, unit-testable core
# ---------------------------------------------------------------------------

def test_restart_plan_is_ordered_code_serving_set():
    """The plan is the exact ordered set of code-serving user services."""
    from axi import redeploy

    plan = redeploy.restart_plan()
    assert plan == [
        "axi-dashboard.service",
        "axi-whisper.service",
        "axi-voice.service",
        "axi-tray.service",
        "axi-heartbeat.service",
    ]


def test_restart_plan_dashboard_first():
    """Dashboard (the incident service, stateless) is restarted first."""
    from axi import redeploy

    assert redeploy.restart_plan()[0] == "axi-dashboard.service"


def test_restart_plan_heartbeat_last():
    """The supervisor restarts itself last so it doesn't race the others."""
    from axi import redeploy

    assert redeploy.restart_plan()[-1] == "axi-heartbeat.service"


def test_restart_plan_whisper_before_voice():
    """Whisper (STT backend) comes up before voice, which depends on it."""
    from axi import redeploy

    plan = redeploy.restart_plan()
    assert plan.index("axi-whisper.service") < plan.index("axi-voice.service")


def test_restart_plan_custom_services_passthrough():
    from axi import redeploy

    assert redeploy.restart_plan(["a.service"]) == ["a.service"]


# ---------------------------------------------------------------------------
# redeploy() — the thin, injected CLI core
# ---------------------------------------------------------------------------

def test_redeploy_restarts_every_service_in_order():
    from axi import redeploy

    calls = []
    plan = redeploy.redeploy(run=lambda argv, **kw: calls.append(argv) or _sp_result())

    restarted = [c[-1] for c in calls]
    assert restarted == redeploy.restart_plan()
    assert plan == redeploy.restart_plan()
    # Every call is exactly a user-scoped restart.
    for c in calls:
        assert c[:3] == ["systemctl", "--user", "restart"]


def test_redeploy_dry_run_restarts_nothing():
    from axi import redeploy

    calls = []
    logs: list[str] = []
    plan = redeploy.redeploy(
        dry_run=True,
        run=lambda argv, **kw: calls.append(argv) or _sp_result(),
        log=logs.append,
    )
    assert calls == [], "dry-run must not restart anything"
    assert plan == redeploy.restart_plan()
    # Dry-run still reports what it WOULD do, naming every service.
    joined = " ".join(logs)
    for svc in redeploy.restart_plan():
        assert svc in joined


def test_redeploy_never_touches_git_or_db():
    """axi-redeploy must NOT run git operations nor deploy — only restart."""
    from axi import redeploy

    calls = []
    redeploy.redeploy(run=lambda argv, **kw: calls.append(argv) or _sp_result())
    for c in calls:
        assert "git" not in c
        assert c[0] == "systemctl"
        assert "start" not in c[2:3]  # never plain start, never reset-failed
        assert "reset-failed" not in c


def test_redeploy_idempotent_same_plan_each_call():
    from axi import redeploy

    a = redeploy.redeploy(dry_run=True, log=lambda *_: None)
    b = redeploy.redeploy(dry_run=True, log=lambda *_: None)
    assert a == b == redeploy.restart_plan()


def test_main_dry_run_flag(monkeypatch):
    from axi import redeploy

    seen = {}
    monkeypatch.setattr(
        redeploy, "redeploy",
        lambda **kw: seen.update(kw) or redeploy.restart_plan(),
    )
    rc = redeploy.main(["--dry-run"])
    assert rc == 0
    assert seen.get("dry_run") is True


def test_main_default_is_real_restart(monkeypatch):
    from axi import redeploy

    seen = {}
    monkeypatch.setattr(
        redeploy, "redeploy",
        lambda **kw: seen.update(kw) or redeploy.restart_plan(),
    )
    rc = redeploy.main([])
    assert rc == 0
    assert seen.get("dry_run") is False
