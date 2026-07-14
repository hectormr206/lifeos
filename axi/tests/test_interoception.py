"""Tests for the interoception organ (Pulmones + Olfato).

Pulmones: body_snapshot() vitals + threshold rules (disk, GPU/CPU temp, VRAM).
Olfato: anomaly sniffing (service flapping via NRestarts deltas, warning spikes).
Alerter: per-key episode hysteresis + meeting/game-mode suppression.
"""
from __future__ import annotations

import threading
import time

import pytest

from axi import interoception as intero


# ───────────────────────────── helpers ──────────────────────────────────

def _fake_config(overrides: dict | None = None):
    values = {
        "disk_min_gb_free": 2,
        "body_gpu_temp_max_c": 85,
        "body_cpu_temp_max_c": 90,
        "body_check_interval_s": 120,
        "notify_send_enabled": True,
        "battery_loop_slowdown_factor": 4,
    }
    if overrides:
        values.update(overrides)
    return lambda key, default=None: values.get(key, default)


def _snap(**overrides):
    base = {
        "vram": {"name": "gpu", "used_mb": 1000, "total_mb": 16000,
                 "util_pct": 10, "temp_c": 50},
        "cpu_pct": 5.0,
        "cpu_temp_c": 50,
        "ram": {"used": 100, "total": 1000, "pct": 10.0, "temp_c": None},
        "disk_free_gb": 100.0,
        "on_battery": False,
    }
    base.update(overrides)
    return base


@pytest.fixture(autouse=True)
def _reset():
    intero._reset_for_tests()
    yield
    intero._reset_for_tests()


@pytest.fixture
def quiet(monkeypatch):
    """Neutral environment: config defaults, no suppression, recorded notify."""
    sent: list[tuple[str, str]] = []
    monkeypatch.setattr(intero.config, "get", _fake_config())
    monkeypatch.setattr(intero, "_suppressed", lambda: False)
    monkeypatch.setattr(
        intero, "_notify", lambda message, severity="warning": sent.append((message, severity))
    )
    monkeypatch.setattr(intero, "flapping_alerts", lambda now=None: [])
    monkeypatch.setattr(intero, "warning_spike_alerts", lambda now=None: [])
    return sent


# ───────────────────────── body_snapshot (Pulmones) ─────────────────────

def test_body_snapshot_returns_expected_keys(monkeypatch):
    monkeypatch.setattr(intero, "_vram_snapshot", lambda: {
        "name": "RTX", "used_mb": 100, "total_mb": 1000, "util_pct": 5, "temp_c": 40,
    })
    monkeypatch.setattr(intero, "_ram_snapshot", lambda: {
        "used": 1, "total": 2, "pct": 50.0, "temp_c": None,
    })
    monkeypatch.setattr(intero, "_cpu_pct", lambda: 3.0)
    monkeypatch.setattr(intero, "_cpu_temp_c", lambda: 42)
    monkeypatch.setattr(intero, "disk_free_gb", lambda: 12.5)
    monkeypatch.setattr(intero.power, "on_battery", lambda: False)

    snap = intero.body_snapshot()
    for key in ("vram", "cpu_pct", "cpu_temp_c", "ram", "disk_free_gb", "on_battery"):
        assert key in snap
    assert snap["vram"]["temp_c"] == 40
    assert snap["disk_free_gb"] == 12.5
    assert snap["on_battery"] is False


def test_body_snapshot_without_gpu_yields_none_vram(monkeypatch):
    def _boom(*_a, **_k):
        raise FileNotFoundError("nvidia-smi")
    monkeypatch.setattr(intero.subprocess, "check_output", _boom)
    monkeypatch.setattr(intero, "_ram_snapshot", lambda: {
        "used": 1, "total": 2, "pct": 50.0, "temp_c": None,
    })
    monkeypatch.setattr(intero, "_cpu_pct", lambda: 3.0)
    monkeypatch.setattr(intero, "_cpu_temp_c", lambda: None)
    monkeypatch.setattr(intero, "disk_free_gb", lambda: 12.5)
    monkeypatch.setattr(intero.power, "on_battery", lambda: False)

    snap = intero.body_snapshot()  # must not crash
    assert snap["vram"] is None


# ───────────────────────── vital rules (Pulmones) ────────────────────────

def test_disk_rule_fires_below_threshold(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    alerts = {a["key"]: a for a in intero.vital_alerts(_snap(disk_free_gb=1.3))}
    assert alerts["disk_low"]["firing"] is True
    assert "1.3" in alerts["disk_low"]["message"]


def test_disk_rule_silent_above_threshold(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    alerts = {a["key"]: a for a in intero.vital_alerts(_snap(disk_free_gb=50.0))}
    assert alerts["disk_low"]["firing"] is False


def test_gpu_temp_rule_fires_at_and_above_max(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    hot = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                      "util_pct": 0, "temp_c": 88})
    alerts = {a["key"]: a for a in intero.vital_alerts(hot)}
    assert alerts["gpu_temp_high"]["firing"] is True
    assert "88" in alerts["gpu_temp_high"]["message"]

    exact = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                        "util_pct": 0, "temp_c": 85})
    alerts = {a["key"]: a for a in intero.vital_alerts(exact)}
    assert alerts["gpu_temp_high"]["firing"] is True


def test_gpu_temp_rule_silent_below_max(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    cool = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                       "util_pct": 0, "temp_c": 80})
    alerts = {a["key"]: a for a in intero.vital_alerts(cool)}
    assert alerts["gpu_temp_high"]["firing"] is False


# ───────────────────────── hysteresis (Alerter) ──────────────────────────

def test_hysteresis_fires_once_per_episode(monkeypatch, quiet):
    snap = _snap(disk_free_gb=1.0)
    monkeypatch.setattr(intero, "body_snapshot", lambda: snap)

    first = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in first)
    assert len(quiet) == 1

    second = intero.check_and_alert()  # episode persists → silent
    assert second == []
    assert len(quiet) == 1


def test_hysteresis_new_episode_after_recovery(monkeypatch, quiet):
    state = {"snap": _snap(disk_free_gb=1.0)}
    monkeypatch.setattr(intero, "body_snapshot", lambda: state["snap"])

    intero.check_and_alert()
    assert len(quiet) == 1

    # Recovery must exceed the margin (min 2 GB + 0.5 GB) to close the episode.
    state["snap"] = _snap(disk_free_gb=2.2)  # inside margin → episode persists
    intero.check_and_alert()
    state["snap"] = _snap(disk_free_gb=1.0)
    assert intero.check_and_alert() == []  # same episode, still silent
    assert len(quiet) == 1

    state["snap"] = _snap(disk_free_gb=3.0)  # beyond margin → episode closes
    intero.check_and_alert()
    state["snap"] = _snap(disk_free_gb=1.0)
    fired = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in fired)
    assert len(quiet) == 2


# ───────────────────────── suppression (Alerter) ─────────────────────────

def test_suppression_senses_but_never_notifies(monkeypatch, quiet):
    monkeypatch.setattr(intero, "body_snapshot", lambda: _snap(disk_free_gb=1.0))
    monkeypatch.setattr(intero, "_suppressed", lambda: True)

    fired = intero.check_and_alert()
    assert fired == []
    assert quiet == []
    # It still SENSED the episode: once unsuppressed, the pending alert fires.
    monkeypatch.setattr(intero, "_suppressed", lambda: False)
    fired = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in fired)
    assert len(quiet) == 1


# ───────────────────────── flapping (Olfato) ─────────────────────────────

def test_flapping_fires_at_three_restarts_in_window(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    now = time.time()
    svc = "llama-server.service"
    readings = iter([5, 8])
    reader = lambda _svc: next(readings)  # noqa: E731

    alerts = intero.flapping_alerts(now=now, read_nrestarts=reader, services=[svc])
    assert alerts == [] or all(not a["firing"] for a in alerts)  # baseline pass

    alerts = intero.flapping_alerts(now=now + 60, read_nrestarts=reader, services=[svc])
    firing = [a for a in alerts if a["firing"]]
    assert len(firing) == 1
    assert "llama-server" in firing[0]["message"]
    assert "3" in firing[0]["message"]


def test_flapping_silent_at_two_restarts(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    now = time.time()
    svc = "axi-voice.service"
    readings = iter([5, 7])
    reader = lambda _svc: next(readings)  # noqa: E731

    intero.flapping_alerts(now=now, read_nrestarts=reader, services=[svc])
    alerts = intero.flapping_alerts(now=now + 60, read_nrestarts=reader, services=[svc])
    assert all(not a["firing"] for a in alerts)


# ───────────────────────── warning spike (Olfato) ────────────────────────

def _warnings(source: str, n: int, now: float):
    return [
        {"ts": now - 30, "source": source, "level": "warning",
         "message": "x", "data": None, "unread": True}
        for _ in range(n)
    ]


def test_warning_spike_fires_at_threshold(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    now = time.time()
    monkeypatch.setattr(
        intero.events, "recent_events",
        lambda limit=50, level=None: _warnings("whisper", 10, now),
    )
    alerts = [a for a in intero.warning_spike_alerts(now=now) if a["firing"]]
    assert len(alerts) == 1
    assert "whisper" in alerts[0]["message"]


def test_warning_spike_silent_below_threshold(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    now = time.time()
    monkeypatch.setattr(
        intero.events, "recent_events",
        lambda limit=50, level=None: _warnings("whisper", 9, now),
    )
    assert all(not a["firing"] for a in intero.warning_spike_alerts(now=now))


# ───────────────────────── loop robustness ───────────────────────────────

def test_loop_iteration_never_raises_when_sensors_throw(monkeypatch):
    def _boom(*_a, **_k):
        raise RuntimeError("sensor exploded")

    monkeypatch.setattr(intero, "body_snapshot", _boom)
    monkeypatch.setattr(intero, "flapping_alerts", _boom)
    monkeypatch.setattr(intero, "warning_spike_alerts", _boom)
    monkeypatch.setattr(intero, "_suppressed", _boom)
    monkeypatch.setattr(intero.config, "get", _boom)

    intero._loop_iteration()  # must not raise


def test_loop_stops_on_event(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config({"body_check_interval_s": 30}))
    monkeypatch.setattr(intero, "check_and_alert", lambda: [])
    stop = threading.Event()
    stop.set()  # pre-stopped → loop must exit immediately
    t = threading.Thread(target=intero.run_interoception_loop, args=(stop,))
    t.start()
    t.join(timeout=2)
    assert not t.is_alive()


# ───────────────────────── dashboard regression ──────────────────────────

def test_dashboard_snapshot_keeps_old_keys_and_adds_disk(monkeypatch):
    from fastapi.testclient import TestClient
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

    client = TestClient(dashboard.app)
    r = client.get("/api/snapshot")
    assert r.status_code == 200
    data = r.json()
    for key in ("now", "state", "services", "vram", "ram", "cpu_pct",
                "cpu_temp_c", "disk_free_gb"):
        assert key in data
