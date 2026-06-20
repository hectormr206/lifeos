"""Tests for axi.obs — dual-write lifecycle helper and managed_systemctl stub.

Spec coverage:
- lifecycle() writes to BOTH stdlib logger AND events.log_* (1.8/1.9)
- managed_systemctl() returns unchanged CompletedProcess; events called BEFORE run (1.10/1.11)
"""
from __future__ import annotations

import subprocess
import types
from unittest.mock import MagicMock, call, patch


# ---------------------------------------------------------------------------
# 1.8 / 1.9 — obs.lifecycle dual-write
# ---------------------------------------------------------------------------

def test_lifecycle_dual_write(caplog):
    """lifecycle() calls log.<level>() AND events.log_<level>() with correct args."""
    import logging
    from unittest.mock import MagicMock, patch

    log_mock = MagicMock()
    log_mock.info = MagicMock()

    events_log_info = MagicMock()

    with patch("axi.obs._get_events_log_fn", return_value=events_log_info):
        from axi import obs
        obs.lifecycle(log_mock, "info", "heartbeat", "service started", service="svc-a")

    # stdlib logger was called
    log_mock.info.assert_called_once()
    call_args = log_mock.info.call_args
    # Message arg contains the message text
    assert "service started" in call_args[0][0]

    # events.log_info was called with source, message, and data
    events_log_info.assert_called_once()
    ev_args, ev_kwargs = events_log_info.call_args
    assert ev_args[0] == "heartbeat"   # source
    assert ev_args[1] == "service started"  # message
    # data kwarg includes our extra
    assert ev_kwargs.get("data", {}).get("service") == "svc-a"


def test_lifecycle_warning_level(caplog):
    """lifecycle() at 'warning' level calls log.warning and events.log_warning."""
    from unittest.mock import MagicMock, patch

    log_mock = MagicMock()
    events_log_warning = MagicMock()

    with patch("axi.obs._get_events_log_fn", return_value=events_log_warning):
        from axi import obs
        obs.lifecycle(log_mock, "warning", "heartbeat", "cap exhausted", reason="cap_exhausted")

    log_mock.warning.assert_called_once()
    events_log_warning.assert_called_once()
    ev_args, ev_kwargs = events_log_warning.call_args
    assert ev_args[0] == "heartbeat"
    assert ev_kwargs.get("data", {}).get("reason") == "cap_exhausted"


def test_lifecycle_extras_in_log_message():
    """lifecycle() appends key=value extras to the log message."""
    from unittest.mock import MagicMock, patch

    log_mock = MagicMock()
    events_fn = MagicMock()

    with patch("axi.obs._get_events_log_fn", return_value=events_fn):
        from axi import obs
        obs.lifecycle(log_mock, "info", "heartbeat", "ensure_up", service="llama-vt.service", action="start")

    # The message passed to log.info should contain the extras
    call_args = log_mock.info.call_args[0][0]
    assert "service=llama-vt.service" in call_args or "service" in call_args


# ---------------------------------------------------------------------------
# 1.10 / 1.11 — managed_systemctl returns CompletedProcess; events BEFORE run
# ---------------------------------------------------------------------------

def test_managed_systemctl_returns_completed_process():
    """managed_systemctl returns the subprocess.CompletedProcess unchanged."""
    from unittest.mock import MagicMock, patch

    fake_result = subprocess.CompletedProcess(
        args=["systemctl", "--user", "start", "llama-vt.service"],
        returncode=0,
        stdout="",
        stderr="",
    )

    with patch("axi.obs._get_events_log_fn", return_value=MagicMock()):
        with patch("subprocess.run", return_value=fake_result) as mock_run:
            from axi import obs
            result = obs.managed_systemctl(
                "start", "llama-vt.service",
                caller="heartbeat",
                reason="ensure_up",
            )

    assert result is fake_result, "managed_systemctl must return the CompletedProcess unchanged"


def test_managed_systemctl_events_called_before_run():
    """managed_systemctl calls events BEFORE executing subprocess.run."""
    from unittest.mock import MagicMock, patch, call

    order: list[str] = []

    def fake_events_fn(source, message, *, data=None):
        order.append("events")

    fake_result = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

    def fake_run(*args, **kwargs):
        order.append("run")
        return fake_result

    with patch("axi.obs._get_events_log_fn", return_value=fake_events_fn):
        with patch("subprocess.run", side_effect=fake_run):
            from axi import obs
            obs.managed_systemctl(
                "stop", "llama-vt.service",
                caller="dashboard",
                reason="model_activate",
            )

    assert order == ["events", "run"], (
        f"Expected events before run, got order: {order}"
    )


def test_managed_systemctl_passes_correct_argv():
    """managed_systemctl calls subprocess.run with ['systemctl', '--user', action, service]."""
    from unittest.mock import MagicMock, patch

    captured_args: list = []

    def fake_run(args, **kwargs):
        captured_args.extend(args)
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")

    with patch("axi.obs._get_events_log_fn", return_value=MagicMock()):
        with patch("subprocess.run", side_effect=fake_run):
            from axi import obs
            obs.managed_systemctl(
                "restart", "axi-whisper.service",
                caller="models_manager",
                reason="model_change",
            )

    assert captured_args[:4] == ["systemctl", "--user", "restart", "axi-whisper.service"], (
        f"Unexpected argv: {captured_args}"
    )
