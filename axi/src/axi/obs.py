"""Observability helpers for Axi/LifeOS — obs.py (policy layer).

Sits above events.py (the low-level sink) and stdlib logging. Imports events
lazily to avoid circular imports.

Public API (Slice 1):
    lifecycle(log, level, source, message, **data) -> None
        Dual-writes to BOTH stdlib logger AND events.log_<level>.

    managed_systemctl(action, service, *, caller, reason, check=False, timeout=30)
        Emits an event BEFORE running systemctl; returns the CompletedProcess.

Internal helpers used in tests for patching:
    _get_events_log_fn(level) -> Callable
        Returns the events.log_<level> function for the given level string.
"""
from __future__ import annotations

import logging
import subprocess
from typing import Any, Callable

log = logging.getLogger("axi.obs")


# ---------------------------------------------------------------------------
# Internal helper — lazy import seam (patchable in tests)
# ---------------------------------------------------------------------------

def _get_events_log_fn(level: str) -> Callable:
    """Return events.log_<level> callable; import events lazily to avoid cycles."""
    from axi import events  # lazy import
    fn = getattr(events, f"log_{level}", None)
    if fn is None:
        raise AttributeError(f"axi.events has no attribute log_{level!r}")
    return fn


# ---------------------------------------------------------------------------
# lifecycle() — dual-write helper
# ---------------------------------------------------------------------------

def lifecycle(
    log_: logging.Logger,
    level: str,
    source: str,
    message: str,
    **data: Any,
) -> None:
    """Emit a log record AND a structured event in one call.

    Args:
        log_: The stdlib logger to write to (caller's module logger).
        level: Log level string — 'debug', 'info', 'warning', 'error', 'critical'.
        source: Event source label (e.g. 'heartbeat').
        message: Human-readable message.
        **data: Arbitrary key=value pairs appended to both the log message and event data.

    Both writes are attempted independently. Neither failure is propagated to
    the caller — the observability layer must never crash core logic.
    """
    # Build the logfmt-style message with appended k=v pairs.
    if data:
        kv = " ".join(f"{k}={v}" for k, v in data.items())
        full_message = f"{message} {kv}"
    else:
        full_message = message

    # Write to stdlib logger.
    try:
        log_fn = getattr(log_, level, None)
        if log_fn is None:
            log_fn = log_.info  # fallback
        log_fn(full_message)
    except Exception:  # noqa: BLE001
        pass

    # Write to events log.
    try:
        events_fn = _get_events_log_fn(level)
        events_fn(source, message, data=data)
    except Exception:  # noqa: BLE001
        pass


# ---------------------------------------------------------------------------
# managed_systemctl() — accountability wrapper
# ---------------------------------------------------------------------------

def managed_systemctl(
    action: str,
    service: str,
    *,
    caller: str,
    reason: str,
    check: bool = False,
    timeout: int = 30,
) -> subprocess.CompletedProcess:
    """Emit an accountability event then run systemctl --user <action> <service>.

    The event is ALWAYS emitted before the subprocess call. Returns the
    CompletedProcess unchanged so callers can inspect returncode normally.

    Args:
        action: systemctl action — 'start', 'stop', 'restart', 'reset-failed', etc.
        service: Full service unit name (e.g. 'llama-vt.service').
        caller: Module that is initiating the call (for auditing).
        reason: Human-readable reason string.
        check: If True, raises CalledProcessError on non-zero exit.
        timeout: Seconds before the subprocess call times out.
    """
    # Emit accountability event BEFORE running systemctl.
    try:
        events_fn = _get_events_log_fn("info")
        events_fn(
            caller,
            f"{action} {service}",
            data={"service": service, "caller": caller, "reason": reason, "action": action},
        )
    except Exception:  # noqa: BLE001
        pass

    # Run systemctl --user.
    return subprocess.run(
        ["systemctl", "--user", action, service],
        check=check,
        timeout=timeout,
        capture_output=True,
        text=True,
    )
