"""Tests for axi.reminder_voice — voice reminder fastpath."""

from __future__ import annotations

from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock, patch, call
from zoneinfo import ZoneInfo

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_reminder_intent(message="llamar a mamá", when=None, recurrence=None):
    """Return a fake ReminderIntent without touching the DB."""
    from lifeos.parser import ReminderIntent
    if when is None:
        when = datetime(2026, 5, 23, 15, 0, tzinfo=timezone.utc)
    return ReminderIntent(message=message, when=when, recurrence=recurrence)


def _make_reminder(rid="REM001", message="llamar a mamá", when=None):
    """Return a fake Reminder object."""
    from lifeos.reminders import Reminder
    if when is None:
        when = datetime(2026, 5, 23, 15, 0, tzinfo=timezone.utc)
    return Reminder(
        id=rid,
        when_ts=when,
        message=message,
        channel="push",
        status="pending",
        created_at=when,
        fired_at=None,
        error=None,
        recurrence=None,
    )


# ---------------------------------------------------------------------------
# test_returns_none_when_text_is_not_a_reminder
# ---------------------------------------------------------------------------

def test_returns_none_when_text_is_not_a_reminder():
    """Non-reminder text (no trigger keyword) → returns None; no side effects."""
    from axi.reminder_voice import try_create_reminder

    with patch("axi.reminder_voice.parse_reminder", return_value=None) as mock_parse:
        result = try_create_reminder("hola Axi")

    assert result is None
    mock_parse.assert_called_once()


# ---------------------------------------------------------------------------
# test_creates_reminder_when_parser_succeeds
# ---------------------------------------------------------------------------

def test_creates_reminder_when_parser_succeeds():
    """Full happy path: parse returns intent → create + schedule + notify + return rid."""
    from axi.reminder_voice import try_create_reminder

    intent = _make_reminder_intent()
    fake_rem = _make_reminder()

    with (
        patch("axi.reminder_voice.parse_reminder", return_value=intent),
        patch("axi.reminder_voice.reminders.create", return_value=fake_rem) as mock_create,
        patch("axi.reminder_voice.get_scheduler") as mock_get_sched,
        patch("axi.reminder_voice.notify") as mock_notify,
    ):
        mock_sched = MagicMock()
        mock_get_sched.return_value = mock_sched

        result = try_create_reminder("Axi, recordame llamar a mamá mañana a las 9")

    assert result == "REM001"

    # create() must be called with the right kwargs
    mock_create.assert_called_once_with(
        when=intent.when,
        message=intent.message,
        channel="push",
        recurrence=intent.recurrence,
    )

    # scheduler.schedule(reminder) must be called
    mock_sched.schedule.assert_called_once_with(fake_rem)

    # notify must fire once
    mock_notify.assert_called_once()
    title, *_ = mock_notify.call_args.args
    assert "Axi" in title or mock_notify.call_args.kwargs.get("title", "")


# ---------------------------------------------------------------------------
# test_handles_parser_returning_none
# ---------------------------------------------------------------------------

def test_handles_parser_returning_none():
    """parse_reminder returns None → helper returns None; create never called."""
    from axi.reminder_voice import try_create_reminder

    with (
        patch("axi.reminder_voice.parse_reminder", return_value=None),
        patch("axi.reminder_voice.reminders.create") as mock_create,
    ):
        result = try_create_reminder("recordame algo")

    assert result is None
    mock_create.assert_not_called()


# ---------------------------------------------------------------------------
# test_handles_create_failure
# ---------------------------------------------------------------------------

def test_handles_create_failure():
    """If reminders.create raises, helper swallows the error and returns None."""
    from axi.reminder_voice import try_create_reminder

    intent = _make_reminder_intent()

    with (
        patch("axi.reminder_voice.parse_reminder", return_value=intent),
        patch("axi.reminder_voice.reminders.create", side_effect=RuntimeError("DB locked")),
        patch("axi.reminder_voice.notify") as mock_notify,
    ):
        result = try_create_reminder("Axi, recordame algo")

    assert result is None
    # No notification should fire on failure
    mock_notify.assert_not_called()


# ---------------------------------------------------------------------------
# test_brain_fallback_is_wired
# ---------------------------------------------------------------------------

def test_brain_fallback_is_wired():
    """parse_reminder is called with brain_fallback=parse_when_brain."""
    from axi.reminder_voice import try_create_reminder
    from axi.reminder_brain import parse_when_brain

    captured = {}

    def fake_parse(text, *, brain_fallback=None, **kwargs):
        captured["brain_fallback"] = brain_fallback
        return None  # no reminder — just capturing the kwarg

    with patch("axi.reminder_voice.parse_reminder", side_effect=fake_parse):
        try_create_reminder("recordame algo después de comer")

    assert captured.get("brain_fallback") is parse_when_brain


# ---------------------------------------------------------------------------
# test_pretty_when_format_local_tz
# ---------------------------------------------------------------------------

def test_pretty_when_format_local_tz():
    """Notification body contains a human-readable local-time string."""
    from axi.reminder_voice import try_create_reminder

    # A fixed UTC datetime: Saturday 2026-05-23 20:00 UTC = Saturday 14:00 CDT
    when_utc = datetime(2026, 5, 23, 20, 0, tzinfo=timezone.utc)
    intent = _make_reminder_intent(message="cita con el médico", when=when_utc)
    fake_rem = _make_reminder(rid="REMTZ", message="cita con el médico", when=when_utc)

    notify_calls: list = []

    def capture_notify(*args, **kwargs):
        notify_calls.append((args, kwargs))

    with (
        patch("axi.reminder_voice.parse_reminder", return_value=intent),
        patch("axi.reminder_voice.reminders.create", return_value=fake_rem),
        patch("axi.reminder_voice.get_scheduler", return_value=MagicMock()),
        patch("axi.reminder_voice.notify", side_effect=capture_notify),
    ):
        result = try_create_reminder("Axi, recordame la cita con el médico")

    assert result == "REMTZ"
    assert notify_calls, "notify should have been called"

    # Gather all string arguments from the notify call
    all_text = " ".join(
        str(a) for a in notify_calls[0][0]
    ) + " " + " ".join(
        str(v) for v in notify_calls[0][1].values()
    )

    # The local time in America/Mexico_City for 2026-05-23 20:00 UTC is 14:00 CDT.
    # We expect "14:00" or "14:" to appear in the notification body.
    assert "14:00" in all_text or "14:" in all_text, (
        f"Expected local time '14:00' in notification text, got: {all_text!r}"
    )
