"""Regression test: the correlation_snapshot job must be registered at startup.

P6.3's hourly `correlation_snapshot` job (lifeos.insights.correlate.register) was
fully coded but never wired into the dashboard lifespan, so it never ran in
production. This test pins the wiring: after the FastAPI lifespan starts, the
lifeos scheduler must own the `lifeos.insights.correlation_snapshot` job.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

CORRELATION_JOB_ID = "lifeos.insights.correlation_snapshot"


@pytest.fixture()
def dashboard_module(monkeypatch, tmp_path):
    """Point lifeos stores at temp files and stub the heavy host probes."""
    for var, name in (
        ("LIFEOS_DB_PATH", "lifeos.db"),
        ("LIFEOS_KEY_PATH", "lifeos.key"),
        ("LIFEOS_STATE_DIR", "state"),
        ("LIFEOS_HEALTH_DB_PATH", "health.db"),
        ("LIFEOS_HEALTH_KEY_PATH", "health.key"),
        ("LIFEOS_FINANCE_DB_PATH", "finance.db"),
        ("LIFEOS_FINANCE_KEY_PATH", "finance.key"),
        ("LIFEOS_REL_DB_PATH", "rel.db"),
        ("LIFEOS_REL_KEY_PATH", "rel.key"),
        ("LIFEOS_EXERCISE_DB_PATH", "ex.db"),
        ("LIFEOS_EXERCISE_KEY_PATH", "ex.key"),
        ("LIFEOS_SPIRIT_DB_PATH", "spirit.db"),
        ("LIFEOS_SPIRIT_KEY_PATH", "spirit.key"),
        ("LIFEOS_LEARNING_DB_PATH", "learn.db"),
        ("LIFEOS_LEARNING_KEY_PATH", "learn.key"),
        ("LIFEOS_EVENTS_DB_PATH", "ev.db"),
        ("LIFEOS_EVENTS_KEY_PATH", "ev.key"),
    ):
        monkeypatch.setenv(var, str(tmp_path / name))

    from axi import dashboard

    # Stub host probes so the lifespan does not touch real hardware/services.
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    # Keep posture cron from arming real screen capture during startup.
    monkeypatch.setattr(dashboard.posture_cron, "start_jobs", lambda *_a, **_k: None)

    return dashboard


def test_correlation_snapshot_job_registered_on_startup(dashboard_module) -> None:
    """Entering the lifespan must register the hourly correlation_snapshot job."""
    from lifeos.scheduler import get_scheduler

    with TestClient(dashboard_module.app):
        sched = get_scheduler()
        job = sched._scheduler.get_job(CORRELATION_JOB_ID)
        assert job is not None, (
            "correlation_snapshot job was not registered at startup — "
            "correlate.register(sched) is missing from the lifespan"
        )
