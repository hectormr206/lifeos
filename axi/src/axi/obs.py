"""Observability helpers for Axi/LifeOS — obs.py (policy layer).

Sits above events.py (the low-level sink) and stdlib logging. Imports events
lazily to avoid circular imports.

Public API (Slice 1):
    lifecycle(log, level, source, message, **data) -> None
        Dual-writes to BOTH stdlib logger AND events.log_<level>.

    managed_systemctl(action, service, *, caller, reason, check=False, timeout=30)
        Emits an event BEFORE running systemctl; returns the CompletedProcess.

Public API (Slice 4):
    get_request_id() -> str
        Returns the current request_id from the ContextVar (default "-").

    set_request_id(rid) -> None
        Sets the request_id ContextVar for the current async task / thread.

    install_request_id_middleware(app) -> None
        Registers an HTTP middleware on a FastAPI app that sets/resets the
        request_id ContextVar for every incoming request.

Internal helpers used in tests for patching:
    _get_events_log_fn(level) -> Callable
        Returns the events.log_<level> function for the given level string.
"""
from __future__ import annotations

import logging
import subprocess
import uuid
from contextvars import ContextVar
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Slice 4 — request_id correlation via ContextVar
# ---------------------------------------------------------------------------

# Default is "-" so log lines outside an HTTP request always have a stable value.
_request_id_var: ContextVar[str] = ContextVar("request_id", default="-")


def get_request_id() -> str:
    """Return the current request_id (default '-' when not in an HTTP request)."""
    return _request_id_var.get()


def set_request_id(rid: str) -> None:
    """Set the request_id ContextVar for the current execution context."""
    _request_id_var.set(rid)

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
    result = subprocess.run(
        ["systemctl", "--user", action, service],
        check=check,
        timeout=timeout,
        capture_output=True,
        text=True,
    )

    # Emit a warning event when the command fails so failures are visible in
    # the event log even when callers pass check=False.
    if result is not None and result.returncode != 0:
        try:
            warning_fn = _get_events_log_fn("warning")
            warning_fn(
                caller,
                f"{action} {service} failed rc={result.returncode}",
                data={
                    "service": service,
                    "action": action,
                    "returncode": result.returncode,
                    "stderr": result.stderr[:500] if result.stderr else "",
                },
            )
        except Exception:  # noqa: BLE001
            pass

    return result


# ---------------------------------------------------------------------------
# Slice 4 — FastAPI middleware helper
# ---------------------------------------------------------------------------


def install_request_id_middleware(app: Any) -> None:
    """Register an HTTP middleware on *app* that sets/resets request_id.

    Generates a short UUID4-based id for each incoming request, stores it in
    the ContextVar via set_request_id(), and resets to "-" after the response
    so no request_id leaks between requests in the same async task.

    Usage (dashboard.py):
        from axi import obs
        obs.install_request_id_middleware(app)
    """
    from starlette.middleware.base import BaseHTTPMiddleware
    from starlette.requests import Request

    class _ReqIdMiddleware(BaseHTTPMiddleware):
        async def dispatch(self, request: Request, call_next):
            # Prefer an incoming X-Request-Id header; generate one if absent.
            rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
            # Use token-based reset so nested set/reset pairs are nesting-safe
            # and the outer ContextVar value is always restored.
            token = _request_id_var.set(rid)
            try:
                response = await call_next(request)
                return response
            finally:
                _request_id_var.reset(token)

    app.add_middleware(_ReqIdMiddleware)
