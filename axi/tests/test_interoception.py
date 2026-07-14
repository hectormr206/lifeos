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
        "body_game_gpu_temp_max_c": 92,
        "body_game_cpu_temp_max_c": 95,
        "body_battery_care_enabled": True,
        "body_battery_full_days": 7,
        "body_battery_replug_pct": 40,
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
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
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
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "meeting")

    fired = intero.check_and_alert()
    assert fired == []
    assert quiet == []
    # It still SENSED the episode: once unsuppressed, the pending alert fires.
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
    fired = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in fired)
    assert len(quiet) == 1


# ───────────────────── suppression reason (game vs meeting) ──────────────

def test_suppression_reason_none_when_quiet(monkeypatch):
    monkeypatch.setattr(intero, "_meeting_active", lambda: False)
    monkeypatch.setattr(intero, "_game_active", lambda: False)
    assert intero._suppression_reason() is None


def test_suppression_reason_game(monkeypatch):
    monkeypatch.setattr(intero, "_meeting_active", lambda: False)
    monkeypatch.setattr(intero, "_game_active", lambda: True)
    assert intero._suppression_reason() == "game"


def test_suppression_reason_meeting_wins_over_game(monkeypatch):
    monkeypatch.setattr(intero, "_meeting_active", lambda: True)
    monkeypatch.setattr(intero, "_game_active", lambda: True)
    assert intero._suppression_reason() == "meeting"


def test_suppression_reason_failsafe_uncertain_meeting(monkeypatch):
    # Unknown meeting state → fail-safe 'meeting' (full suppression).
    monkeypatch.setattr(intero, "_meeting_active", lambda: None)
    monkeypatch.setattr(intero, "_game_active", lambda: False)
    assert intero._suppression_reason() == "meeting"


# ───────────────────── game-mode calibration (Pulmones) ──────────────────

def test_vram_rule_disabled_during_game(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    full = _snap(vram={"name": "g", "used_mb": 15500, "total_mb": 16000,
                       "util_pct": 99, "temp_c": 70})
    keys = {a["key"] for a in intero.vital_alerts(full, game_mode=True)}
    assert "vram_full" not in keys
    # Sanity: same snapshot outside game mode DOES evaluate the vram rule.
    keys = {a["key"] for a in intero.vital_alerts(full, game_mode=False)}
    assert "vram_full" in keys


def test_gpu_temp_uses_game_threshold_during_game(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    warm = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                       "util_pct": 0, "temp_c": 88})
    alerts = {a["key"]: a for a in intero.vital_alerts(warm, game_mode=True)}
    assert alerts["gpu_temp_high"]["firing"] is False  # below game max (92)

    danger = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                         "util_pct": 0, "temp_c": 93})
    alerts = {a["key"]: a for a in intero.vital_alerts(danger, game_mode=True)}
    assert alerts["gpu_temp_high"]["firing"] is True
    assert alerts["gpu_temp_high"].get("game_immediate") is True


def test_cpu_temp_uses_game_threshold_during_game(monkeypatch):
    monkeypatch.setattr(intero.config, "get", _fake_config())
    warm = _snap(cpu_temp_c=93)
    alerts = {a["key"]: a for a in intero.vital_alerts(warm, game_mode=True)}
    assert alerts["cpu_temp_high"]["firing"] is False  # below game max (95)

    danger = _snap(cpu_temp_c=96)
    alerts = {a["key"]: a for a in intero.vital_alerts(danger, game_mode=True)}
    assert alerts["cpu_temp_high"]["firing"] is True
    assert alerts["cpu_temp_high"].get("game_immediate") is True


def test_game_mode_thermal_danger_notifies_immediately(monkeypatch, quiet):
    hot = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                      "util_pct": 0, "temp_c": 93})
    monkeypatch.setattr(intero, "body_snapshot", lambda: hot)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    fired = intero.check_and_alert()
    assert any(a["key"] == "gpu_temp_high" for a in fired)
    assert len(quiet) == 1
    assert "93" in quiet[0][0]


def test_game_mode_gpu_below_game_max_stays_silent(monkeypatch, quiet):
    # 88 °C would fire the NORMAL rule (85) but not the game rule (92).
    warm = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                       "util_pct": 0, "temp_c": 88})
    monkeypatch.setattr(intero, "body_snapshot", lambda: warm)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    assert intero.check_and_alert() == []
    assert quiet == []


def test_game_mode_vram_never_alerts(monkeypatch, quiet):
    full = _snap(vram={"name": "g", "used_mb": 15800, "total_mb": 16000,
                       "util_pct": 99, "temp_c": 70})
    monkeypatch.setattr(intero, "body_snapshot", lambda: full)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    assert intero.check_and_alert() == []
    assert quiet == []


def test_game_mode_still_defers_non_thermal(monkeypatch, quiet):
    state = {"snap": _snap(disk_free_gb=1.0)}
    monkeypatch.setattr(intero, "body_snapshot", lambda: state["snap"])
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    assert intero.check_and_alert() == []
    assert quiet == []
    # Game over, disk still low → the deferred episode fires now.
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
    fired = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in fired)
    assert len(quiet) == 1


def test_meeting_defers_even_game_danger_levels(monkeypatch, quiet):
    hot = _snap(vram={"name": "g", "used_mb": 0, "total_mb": 16000,
                      "util_pct": 0, "temp_c": 99})
    monkeypatch.setattr(intero, "body_snapshot", lambda: hot)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "meeting")

    assert intero.check_and_alert() == []
    assert quiet == []


# ───────────────────── re-evaluation on suppression lift ─────────────────

def test_lift_reevaluation_closes_recovered_episode_silently(monkeypatch, quiet):
    state = {"snap": _snap(disk_free_gb=1.0)}
    monkeypatch.setattr(intero, "body_snapshot", lambda: state["snap"])
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    intero.check_and_alert()  # episode opens, deferred
    assert quiet == []

    # Condition recovered BEFORE the game ended → on lift: silence + close.
    state["snap"] = _snap(disk_free_gb=30.0)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
    assert intero.check_and_alert() == []
    assert quiet == []
    assert "disk_low" not in intero._episodes

    # A LATER genuine recurrence is a fresh episode and notifies.
    state["snap"] = _snap(disk_free_gb=1.0)
    fired = intero.check_and_alert()
    assert any(a["key"] == "disk_low" for a in fired)
    assert len(quiet) == 1


def test_lift_reevaluation_fires_only_still_failing(monkeypatch, quiet):
    # Two episodes open during a meeting; only one still holds at lift.
    state = {"snap": _snap(disk_free_gb=1.0, cpu_temp_c=96)}
    monkeypatch.setattr(intero, "body_snapshot", lambda: state["snap"])
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "meeting")

    intero.check_and_alert()
    assert quiet == []

    # CPU cooled down, disk is still low.
    state["snap"] = _snap(disk_free_gb=1.0, cpu_temp_c=50)
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
    fired = intero.check_and_alert()
    assert [a["key"] for a in fired] == ["disk_low"]
    assert len(quiet) == 1
    assert "cpu_temp_high" not in intero._episodes


# ───────────────────── battery care (Pulmones) ───────────────────────────

DAY = 86400.0
T0 = 1_700_000_000.0


def _battery_snap(pct=100, on_battery=False, status="Full"):
    return _snap(
        battery_pct=pct,
        battery_status=status,
        battery_health_pct=96.0,
        battery_cycles=0,
        on_battery=on_battery,
    )


@pytest.fixture
def battery_state(monkeypatch, tmp_path):
    path = tmp_path / "interoception_battery.json"
    monkeypatch.setattr(intero, "_battery_state_path", lambda: path)
    monkeypatch.setattr(intero.config, "get", _fake_config())
    return path


def test_battery_sysfs_snapshot_reads_fields(monkeypatch, tmp_path):
    (tmp_path / "capacity").write_text("99\n")
    (tmp_path / "status").write_text("Full\n")
    (tmp_path / "charge_full").write_text("4800000\n")
    (tmp_path / "charge_full_design").write_text("5000000\n")
    (tmp_path / "cycle_count").write_text("12\n")
    monkeypatch.setattr(intero, "_BAT_SYSFS_DIR", tmp_path)

    bat = intero._battery_snapshot()
    assert bat["battery_pct"] == 99
    assert bat["battery_status"] == "Full"
    assert bat["battery_health_pct"] == 96.0
    assert bat["battery_cycles"] == 12


def test_battery_sysfs_snapshot_none_on_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(intero, "_BAT_SYSFS_DIR", tmp_path / "nope")
    bat = intero._battery_snapshot()
    assert bat == {
        "battery_pct": None,
        "battery_status": None,
        "battery_health_pct": None,
        "battery_cycles": None,
    }


def test_body_snapshot_includes_battery_fields(monkeypatch):
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
    monkeypatch.setattr(intero, "_battery_snapshot", lambda: {
        "battery_pct": 98, "battery_status": "Full",
        "battery_health_pct": 95.5, "battery_cycles": 3,
    })

    snap = intero.body_snapshot()
    assert snap["battery_pct"] == 98
    assert snap["battery_status"] == "Full"
    assert snap["battery_health_pct"] == 95.5
    assert snap["battery_cycles"] == 3


def test_battery_unplug_nudge_only_after_n_days(battery_state):
    # Day 0: plugged + full → tracking starts, nothing fires.
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0)}
    assert alerts["battery_unplug"]["firing"] is False

    # Day 6: still short of the 7-day default.
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 6 * DAY)}
    assert alerts["battery_unplug"]["firing"] is False

    # Day 7: fires with the day count in the message.
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 7 * DAY)}
    assert alerts["battery_unplug"]["firing"] is True
    assert alerts["battery_unplug"]["message"] == (
        "Llevas 7 días con la batería llena y conectada. Desconecta el "
        "cargador un rato; te aviso cuando toque reconectar."
    )
    assert alerts["battery_unplug"]["severity"] == "normal"


def test_battery_unplug_nudge_not_repeated_after_advised(battery_state):
    intero.battery_alerts(_battery_snap(), now=T0)
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 7 * DAY)}
    assert alerts["battery_unplug"]["firing"] is True
    alerts["battery_unplug"]["on_notified"]()  # simulate the alerter notifying

    # Next day: advised → silent (no daily nagging).
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 8 * DAY)}
    assert alerts["battery_unplug"]["firing"] is False

    # Another N days without a discharge cycle → nudge again.
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 14 * DAY)}
    assert alerts["battery_unplug"]["firing"] is True


def test_battery_replug_nudge_at_threshold_and_resets_cycle(battery_state):
    import json

    intero.battery_alerts(_battery_snap(), now=T0)  # full_since tracked
    assert json.loads(battery_state.read_text())["full_since"] == T0

    # Discharging above the threshold → silent.
    alerts = {a["key"]: a for a in intero.battery_alerts(
        _battery_snap(pct=60, on_battery=True, status="Discharging"),
        now=T0 + 7 * DAY)}
    assert alerts["battery_replug"]["firing"] is False

    # At/below 40% on battery → replug nudge + full_since reset.
    alerts = {a["key"]: a for a in intero.battery_alerts(
        _battery_snap(pct=38, on_battery=True, status="Discharging"),
        now=T0 + 7 * DAY + 3600)}
    assert alerts["battery_replug"]["firing"] is True
    assert alerts["battery_replug"]["message"] == (
        "La batería llegó a 38%. Reconecta el cargador — ciclo de cuidado completo."
    )
    assert alerts["battery_replug"]["severity"] == "normal"
    saved = json.loads(battery_state.read_text())
    assert saved["full_since"] is None
    assert saved["discharge_advised_at"] is None


def test_battery_care_disabled_produces_no_rules(battery_state, monkeypatch):
    monkeypatch.setattr(
        intero.config, "get", _fake_config({"body_battery_care_enabled": False})
    )
    assert intero.battery_alerts(_battery_snap(), now=T0) == []


def test_battery_alerts_noop_without_battery(battery_state):
    snap = _snap()  # no battery_pct key (e.g. desktop) → no rules, no state IO
    assert intero.battery_alerts(snap, now=T0) == []
    assert not battery_state.exists()


def test_battery_state_persists_across_restarts(battery_state):
    intero.battery_alerts(_battery_snap(), now=T0)
    intero._reset_for_tests()  # daemon restart: in-memory episodes gone

    # full_since survived on disk → day 7 still fires on the fresh "process".
    alerts = {a["key"]: a for a in
              intero.battery_alerts(_battery_snap(), now=T0 + 7 * DAY)}
    assert alerts["battery_unplug"]["firing"] is True


def test_battery_nudges_defer_during_game_and_reevaluate(
        battery_state, monkeypatch, quiet):
    import json

    battery_state.write_text(json.dumps(
        {"full_since": T0 - 8 * DAY, "discharge_advised_at": None}))
    state = {"snap": _battery_snap()}
    monkeypatch.setattr(intero, "body_snapshot", lambda: state["snap"])
    monkeypatch.setattr(intero, "_suppression_reason", lambda: "game")

    assert intero.check_and_alert(now=T0) == []  # advice, not danger → defer
    assert quiet == []

    # Game ends, still plugged+full → the deferred nudge fires once.
    monkeypatch.setattr(intero, "_suppression_reason", lambda: None)
    fired = intero.check_and_alert(now=T0 + 3600)
    assert any(a["key"] == "battery_unplug" for a in fired)
    assert len(quiet) == 1
    assert "batería llena" in quiet[0][0]

    # advised_at was persisted at notification time, not at rule-eval time.
    assert json.loads(battery_state.read_text())["discharge_advised_at"] is not None


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
    monkeypatch.setattr(intero, "_suppression_reason", _boom)
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
