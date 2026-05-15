"""Tests for axi.doctor health checks (PRD P2.2, P2.3)."""
from __future__ import annotations

import sys
import types

import pytest

from axi import doctor
from axi.doctor import Result, _check_audio_devices


# ─────────────────────────── P2.2 — audio ───────────────────────────


def _fake_sounddevice(devices, default_idx=0):
    """Build an in-memory stand-in for the sounddevice module."""
    mod = types.SimpleNamespace()
    mod.query_devices = lambda: devices
    mod.default = types.SimpleNamespace(device=(default_idx, default_idx))
    return mod


def test_audio_check_no_crash_with_real_import(monkeypatch):
    """The function must run end-to-end without raising, regardless of
    whether the host has a working audio stack."""
    r = Result()
    _check_audio_devices(r)
    # No assertion on pass/fail — just no exception.
    assert isinstance(r.failures, list)


def test_audio_check_fails_when_no_inputs(monkeypatch):
    fake = _fake_sounddevice(devices=[])
    monkeypatch.setitem(sys.modules, "sounddevice", fake)
    r = Result()
    _check_audio_devices(r)
    assert any("no input devices" in reason for _, reason in r.failures)


def test_audio_check_ok_with_at_least_one_input(monkeypatch):
    devices = [
        {"name": "Built-in Mic", "max_input_channels": 2, "default_samplerate": 48000.0},
        {"name": "Speakers", "max_input_channels": 0, "default_samplerate": 48000.0},
    ]
    fake = _fake_sounddevice(devices=devices, default_idx=0)
    monkeypatch.setitem(sys.modules, "sounddevice", fake)
    r = Result()
    _check_audio_devices(r)
    assert r.failures == []


def test_audio_check_fails_when_sounddevice_missing(monkeypatch):
    """Simulate an environment where sounddevice cannot be imported."""
    import builtins
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "sounddevice":
            raise ImportError("no sounddevice in this env")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    # Ensure no cached module short-circuits the import.
    monkeypatch.delitem(sys.modules, "sounddevice", raising=False)
    r = Result()
    _check_audio_devices(r)
    assert any("import failed" in reason for _, reason in r.failures)
