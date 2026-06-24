"""Tests for spectacle screen capture — platform-plugin handling.

Regression guard for the Wayland crash: with DISPLAY set alongside
WAYLAND_DISPLAY, Qt picks the xcb platform plugin (missing libxcb-cursor0)
and spectacle aborts with SIGABRT. Forcing QT_QPA_PLATFORM=wayland when a
Wayland session is present routes spectacle to the working plugin.
"""
from __future__ import annotations

import subprocess
from types import SimpleNamespace

from axi import vision


def _fake_run_factory(captured: dict):
    def _fake_run(args, **kwargs):
        captured["args"] = args
        captured["env"] = kwargs.get("env")
        # Simulate a successful capture: write nothing, return rc 0. The caller
        # reads the out file which won't exist → returns None, which is fine;
        # we only assert on how spectacle was invoked.
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
    return _fake_run


def test_spectacle_forces_wayland_platform_when_wayland_session(monkeypatch):
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-0")
    monkeypatch.setenv("DISPLAY", ":0")  # the trap that makes Qt pick xcb
    monkeypatch.setattr(vision.shutil, "which", lambda _: "/usr/bin/spectacle")
    captured: dict = {}
    monkeypatch.setattr(subprocess, "run", _fake_run_factory(captured))

    vision._spectacle_capture(active_only=True)

    env = captured["env"]
    assert env is not None, "spectacle must run with an explicit env on Wayland"
    assert env.get("QT_QPA_PLATFORM") == "wayland", (
        "QT_QPA_PLATFORM must be forced to 'wayland' so Qt does not fall back "
        "to the broken xcb plugin when DISPLAY is set"
    )


def test_spectacle_does_not_force_platform_without_wayland(monkeypatch):
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.setattr(vision.shutil, "which", lambda _: "/usr/bin/spectacle")
    captured: dict = {}
    monkeypatch.setattr(subprocess, "run", _fake_run_factory(captured))

    vision._spectacle_capture(active_only=True)

    env = captured["env"]
    # On a non-Wayland session we must not force wayland (would break pure X).
    if env is not None:
        assert env.get("QT_QPA_PLATFORM") != "wayland"
