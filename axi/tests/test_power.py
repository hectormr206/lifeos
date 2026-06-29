"""Tests for axi.power — battery-aware state reading + evict marker."""
from __future__ import annotations

from pathlib import Path

import pytest

from axi import power


@pytest.fixture(autouse=True)
def _isolate_env(tmp_path, monkeypatch):
    """Point the state file + XDG_STATE_HOME at a tmp dir; clear AC override."""
    monkeypatch.setenv("AXI_POWER_STATE_FILE", str(tmp_path / "power-mode.state"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    # Default: no AC sysfs node available so fallback resolves to the final "ac".
    monkeypatch.setattr(power, "_AC_SYSFS", tmp_path / "missing-ac-online")
    return tmp_path


def _write_state(tmp_path: Path, value: str) -> None:
    (tmp_path / "power-mode.state").write_text(value)


def test_reads_battery(tmp_path):
    _write_state(tmp_path, "battery\n")  # trailing newline from echo
    assert power.power_state() == "battery"
    assert power.on_battery() is True


def test_reads_ac(tmp_path):
    _write_state(tmp_path, "ac\n")
    assert power.power_state() == "ac"
    assert power.on_battery() is False


def test_strips_and_lowercases(tmp_path):
    _write_state(tmp_path, "  BATTERY  \n")
    assert power.power_state() == "battery"


def test_missing_file_falls_back_to_sysfs_battery(tmp_path, monkeypatch):
    # No state file. AC sysfs says 0 -> battery.
    ac_node = tmp_path / "ac-online"
    ac_node.write_text("0\n")
    monkeypatch.setattr(power, "_AC_SYSFS", ac_node)
    assert power.power_state() == "battery"


def test_missing_file_falls_back_to_sysfs_ac(tmp_path, monkeypatch):
    ac_node = tmp_path / "ac-online"
    ac_node.write_text("1\n")
    monkeypatch.setattr(power, "_AC_SYSFS", ac_node)
    assert power.power_state() == "ac"


def test_no_file_no_sysfs_defaults_to_ac(tmp_path):
    # Neither the state file nor the AC node exist -> never throttle on uncertainty.
    assert power.power_state() == "ac"
    assert power.on_battery() is False


def test_garbage_contents_falls_back(tmp_path, monkeypatch):
    _write_state(tmp_path, "potato")
    ac_node = tmp_path / "ac-online"
    ac_node.write_text("0\n")
    monkeypatch.setattr(power, "_AC_SYSFS", ac_node)
    assert power.power_state() == "battery"


def test_battery_scaled_on_battery(tmp_path):
    _write_state(tmp_path, "battery\n")
    assert power.battery_scaled(300, 4) == 1200


def test_battery_scaled_on_ac_unchanged(tmp_path):
    _write_state(tmp_path, "ac\n")
    assert power.battery_scaled(300, 4) == 300


def test_battery_scaled_factor_one_unchanged(tmp_path):
    _write_state(tmp_path, "battery\n")
    assert power.battery_scaled(300, 1) == 300


def test_battery_scaled_bad_factor_unchanged(tmp_path):
    _write_state(tmp_path, "battery\n")
    assert power.battery_scaled(300, None) == 300
