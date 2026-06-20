"""Centralized logging configuration for Axi/LifeOS.

Provides a single setup_logging() entry point that all process entry points
must call instead of logging.basicConfig(). Idempotent: calling twice swaps
the managed handler, never duplicates it, and never removes third-party handlers.

Logfmt-style: base format + appended key=value pairs from record.extra_fields.
Optional RotatingFileHandler (10 MB, 5 backups); degrades gracefully when the
path is not writable — stderr StreamHandler always remains.
"""
from __future__ import annotations

import logging
import logging.handlers
import sys
from typing import Optional

# Tag attribute name used to identify handlers owned by setup_logging.
_MANAGED_TAG = "_axi_managed"

# Base logfmt-style format string.
_BASE_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"


class LogfmtFormatter(logging.Formatter):
    """Formatter that appends extra key=value pairs from record.extra_fields.

    Usage:
        log.info("msg", extra={"extra_fields": {"service": "svc", "reason": "failed"}})

    The output becomes:
        2026-01-01 00:00:00,000 INFO axi.heartbeat msg service=svc reason=failed
    """

    def __init__(self) -> None:
        super().__init__(fmt=_BASE_FORMAT)

    def format(self, record: logging.LogRecord) -> str:
        base = super().format(record)
        extra_fields: dict = getattr(record, "extra_fields", {}) or {}
        if extra_fields:
            kv_pairs = " ".join(f"{k}={v}" for k, v in extra_fields.items())
            return f"{base} {kv_pairs}"
        return base


class ReqIdFilter(logging.Filter):
    """Inject the current request_id into every LogRecord as record.req_id.

    The value is read from obs.get_request_id() which defaults to "-" outside
    an HTTP request. Adding this filter to managed handlers ensures every log
    line carries a stable req_id field for correlation.
    """

    def filter(self, record: logging.LogRecord) -> bool:  # noqa: A003
        try:
            from axi.obs import get_request_id  # lazy to avoid circular import
            record.req_id = get_request_id()
        except Exception:  # noqa: BLE001
            record.req_id = "-"
        return True


def _is_managed(handler: logging.Handler) -> bool:
    return bool(getattr(handler, _MANAGED_TAG, False))


def setup_logging(
    level: int = logging.INFO,
    rotating_file: Optional[str] = None,
) -> None:
    """Configure the root logger with a logfmt-style StreamHandler.

    Idempotent: removes any previously registered managed handlers, then adds
    a fresh managed StreamHandler (and optional RotatingFileHandler). Third-party
    handlers (not tagged _axi_managed) are never touched.

    Args:
        level: Logging level for the root logger (default INFO).
        rotating_file: Optional path for a RotatingFileHandler. If the path
            is not writable, a warning is emitted and the file handler is
            silently skipped — the StreamHandler remains active.
    """
    root = logging.getLogger()
    root.setLevel(level)

    # Remove any previously registered managed handlers (idempotency swap).
    for handler in list(root.handlers):
        if _is_managed(handler):
            root.removeHandler(handler)
            try:
                handler.close()
            except Exception:  # noqa: BLE001
                pass

    formatter = LogfmtFormatter()
    req_id_filter = ReqIdFilter()

    # Always attach a stderr StreamHandler.
    stream_handler = logging.StreamHandler(sys.stderr)
    stream_handler.setFormatter(formatter)
    stream_handler.setLevel(level)
    stream_handler.addFilter(req_id_filter)
    setattr(stream_handler, _MANAGED_TAG, True)
    root.addHandler(stream_handler)

    # Optionally attach a RotatingFileHandler.
    if rotating_file is not None:
        try:
            file_handler = logging.handlers.RotatingFileHandler(
                rotating_file,
                maxBytes=10 * 1024 * 1024,  # 10 MB
                backupCount=5,
                encoding="utf-8",
            )
            file_handler.setFormatter(formatter)
            file_handler.setLevel(level)
            file_handler.addFilter(req_id_filter)
            setattr(file_handler, _MANAGED_TAG, True)
            root.addHandler(file_handler)
        except OSError as exc:
            # Path not writable — degrade gracefully, do NOT crash.
            root.warning(
                "setup_logging: could not open rotating log file %r: %s — continuing without it",
                rotating_file,
                exc,
            )
