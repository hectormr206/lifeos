"""Tests for the libnotify hook on critical/error events (P2.5)."""
from __future__ import annotations

import pytest

from axi import events


@pytest.fixture(autouse=True)
def _reset_state():
    events._reset_for_tests()
    events._reset_notify_for_tests()
    yield
    events._reset_for_tests()
    events._reset_notify_for_tests()


def test_notify_fires_on_critical(monkeypatch):
    calls = []

    def fake_popen(cmd, **kw):
        calls.append(cmd)
        class _P:
            pass
        return _P()

    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen", fake_popen)
    events.log_critical("daemon", "se cayó algo")
    assert len(calls) == 1
    cmd = calls[0]
    assert cmd[0] == "/usr/bin/notify-send"
    assert "-u" in cmd and "critical" in cmd
    assert "Axi · daemon" in cmd
    assert "se cayó algo" in cmd


def test_notify_fires_on_error(monkeypatch):
    calls = []
    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen",
                        lambda cmd, **kw: calls.append(cmd) or object())
    events.log_error("vision", "captura falló")
    assert len(calls) == 1
    assert "normal" in calls[0]  # error → normal urgency


def test_rate_limit_blocks_second_call_within_5min(monkeypatch):
    calls = []
    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen",
                        lambda cmd, **kw: calls.append(cmd) or object())
    events.log_critical("daemon", "uno")
    events.log_critical("daemon", "dos")
    assert len(calls) == 1


def test_kill_switch_disables_notify(monkeypatch):
    calls = []
    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen",
                        lambda cmd, **kw: calls.append(cmd) or object())
    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: False if key == "notify_send_enabled" else default,
    )
    events.log_critical("daemon", "silencio")
    assert calls == []


def test_notify_send_missing_does_not_crash(monkeypatch):
    monkeypatch.setattr(events.shutil, "which", lambda b: None)
    # Must not raise.
    events.log_critical("daemon", "no binary")


def test_info_does_not_notify(monkeypatch):
    calls = []
    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen",
                        lambda cmd, **kw: calls.append(cmd) or object())
    events.log_info("daemon", "todo bien")
    events.log_warning("daemon", "ojo")
    assert calls == []


def test_popen_failure_swallowed(monkeypatch):
    def boom(cmd, **kw):
        raise OSError("boom")
    monkeypatch.setattr(events.shutil, "which", lambda b: "/usr/bin/notify-send")
    monkeypatch.setattr(events.subprocess, "Popen", boom)
    # Must not raise.
    events.log_critical("daemon", "crash test")
