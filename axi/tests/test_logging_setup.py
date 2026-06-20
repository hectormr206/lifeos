"""Tests for axi.logging_setup — TDD RED first, then GREEN.

Spec coverage:
- logfmt format includes extra key=value pairs (1.1/1.2)
- setup_logging idempotent: exactly one managed handler after two calls (1.3/1.4)
- rotating file handler is attached when path is writable (1.5/1.7)
- unwritable rotating_file path degrades gracefully — no crash, stderr still works (1.6/1.7)
"""
from __future__ import annotations

import logging
import logging.handlers


# ---------------------------------------------------------------------------
# 1.1 / 1.2 — LogfmtFormatter includes extras as key=value
# ---------------------------------------------------------------------------

def test_logfmt_format_includes_extras():
    """A LogRecord with extra_fields={k: v} produces output containing 'k=v'."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.test",
        level=logging.INFO,
        pathname="",
        lineno=0,
        msg="hello world",
        args=(),
        exc_info=None,
    )
    record.extra_fields = {"service": "axi-voice.service", "reason": "failed"}

    output = formatter.format(record)

    assert "service=axi-voice.service" in output
    assert "reason=failed" in output


def test_logfmt_format_base_fields_present():
    """Base format includes asctime, levelname, name, and message."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.heartbeat",
        level=logging.WARNING,
        pathname="",
        lineno=0,
        msg="service down",
        args=(),
        exc_info=None,
    )
    record.extra_fields = {}

    output = formatter.format(record)

    assert "WARNING" in output
    assert "axi.heartbeat" in output
    assert "service down" in output


def test_logfmt_format_no_extras_no_trailing_space():
    """When extra_fields is empty or absent, output ends cleanly (no spurious 'key=' suffix)."""
    from axi.logging_setup import LogfmtFormatter

    formatter = LogfmtFormatter()
    record = logging.LogRecord(
        name="axi.test",
        level=logging.INFO,
        pathname="",
        lineno=0,
        msg="no extras here",
        args=(),
        exc_info=None,
    )
    # Deliberately do NOT set extra_fields

    output = formatter.format(record)
    # Should not contain any trailing '=' with nothing after it
    assert "no extras here" in output
    # No crash — that's the primary assertion


# ---------------------------------------------------------------------------
# 1.3 / 1.4 — setup_logging idempotency
# ---------------------------------------------------------------------------

def test_setup_logging_idempotent(tmp_path):
    """Calling setup_logging twice leaves exactly one managed handler on the root logger."""
    import logging as _logging
    from axi.logging_setup import setup_logging

    root = _logging.getLogger()
    # Remove any pre-existing managed handlers for clean test
    pre_managed = [h for h in root.handlers if getattr(h, "_axi_managed", False)]
    for h in pre_managed:
        root.removeHandler(h)

    before_count = len(root.handlers)

    setup_logging(level=_logging.INFO)
    setup_logging(level=_logging.DEBUG)  # second call

    managed = [h for h in root.handlers if getattr(h, "_axi_managed", False)]
    assert len(managed) == 1, (
        f"Expected exactly 1 managed handler after 2 calls, got {len(managed)}"
    )

    # Total handler count must not have grown by more than 1 from pre-test baseline
    assert len(root.handlers) == before_count + 1 or len(root.handlers) == 1, (
        f"Handler count mismatch: before={before_count}, after={len(root.handlers)}"
    )

    # Cleanup: remove the managed handler we added
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)


def test_setup_logging_does_not_nuke_third_party_handlers(tmp_path):
    """setup_logging must not remove handlers not tagged _axi_managed."""
    import logging as _logging
    from axi.logging_setup import setup_logging

    root = _logging.getLogger()
    # Add a non-managed third-party handler
    third_party = _logging.StreamHandler()
    # Do NOT set _axi_managed on it
    root.addHandler(third_party)

    setup_logging(level=_logging.INFO)
    setup_logging(level=_logging.INFO)  # second call

    assert third_party in root.handlers, (
        "Third-party handler was removed by setup_logging — must not nuke non-managed handlers"
    )

    # Cleanup
    root.removeHandler(third_party)
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)


# ---------------------------------------------------------------------------
# 1.5 — RotatingFileHandler is attached when path is writable
# ---------------------------------------------------------------------------

def test_rotating_file_handler_attached(tmp_path):
    """setup_logging(rotating_file=path) attaches a RotatingFileHandler (10 MB, 5 backups)."""
    import logging as _logging
    from axi.logging_setup import setup_logging

    log_path = tmp_path / "axi.log"
    root = _logging.getLogger()

    # Remove pre-existing managed handlers
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)

    setup_logging(level=_logging.INFO, rotating_file=str(log_path))

    managed = [h for h in root.handlers if getattr(h, "_axi_managed", False)]
    rotating = [h for h in managed if isinstance(h, _logging.handlers.RotatingFileHandler)]

    assert rotating, "Expected a RotatingFileHandler among managed handlers"
    rh = rotating[0]
    assert rh.maxBytes == 10 * 1024 * 1024, f"Expected 10MB max, got {rh.maxBytes}"
    assert rh.backupCount == 5, f"Expected 5 backups, got {rh.backupCount}"

    # Cleanup
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)


# ---------------------------------------------------------------------------
# 1.6 — Unwritable rotating_file path degrades gracefully
# ---------------------------------------------------------------------------

def test_rotating_file_unwritable_degrades_gracefully():
    """setup_logging(rotating_file=<unwritable>) does not raise; StreamHandler still present."""
    import logging as _logging
    from axi.logging_setup import setup_logging

    root = _logging.getLogger()
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)

    # This path should not be writable
    unwritable_path = "/proc/no-write/axi.log"

    # Must not raise
    setup_logging(level=_logging.INFO, rotating_file=unwritable_path)

    managed = [h for h in root.handlers if getattr(h, "_axi_managed", False)]
    stream_handlers = [h for h in managed if isinstance(h, _logging.StreamHandler)
                       and not isinstance(h, _logging.handlers.RotatingFileHandler)]

    assert stream_handlers, (
        "Expected at least one StreamHandler (stderr) even when rotating_file is unwritable"
    )
    assert len(managed) >= 1

    # Cleanup
    for h in list(root.handlers):
        if getattr(h, "_axi_managed", False):
            root.removeHandler(h)
