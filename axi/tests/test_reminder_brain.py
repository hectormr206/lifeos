"""Tests for axi.reminder_brain.parse_when_brain."""

from __future__ import annotations

import json
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest


def test_parse_when_brain_returns_datetime_on_valid_json() -> None:
    """A valid JSON response with ISO timestamp returns a tz-aware datetime."""
    from axi.reminder_brain import parse_when_brain

    iso = "2026-05-23T14:00:00-06:00"
    with patch("axi.brain.ask", return_value=json.dumps({"when_iso": iso})):
        result = parse_when_brain("después del almuerzo", "America/Mexico_City")

    assert result is not None
    assert result.tzinfo is not None
    expected = datetime.fromisoformat(iso)
    assert result == expected


def test_parse_when_brain_returns_none_when_brain_says_null() -> None:
    """A JSON response with when_iso: null means the brain couldn't parse it."""
    from axi.reminder_brain import parse_when_brain

    with patch("axi.brain.ask", return_value=json.dumps({"when_iso": None})):
        result = parse_when_brain("cuando termine el gym", "America/Mexico_City")

    assert result is None


def test_parse_when_brain_handles_markdown_fences() -> None:
    """The function strips markdown code fences before parsing JSON."""
    from axi.reminder_brain import parse_when_brain

    iso = "2026-05-23T14:00:00-06:00"
    wrapped = f"```json\n{json.dumps({'when_iso': iso})}\n```"

    with patch("axi.brain.ask", return_value=wrapped):
        result = parse_when_brain("el lunes después del trabajo", "America/Mexico_City")

    assert result is not None
    assert result.tzinfo is not None
    expected = datetime.fromisoformat(iso)
    assert result == expected


def test_parse_when_brain_returns_none_on_invalid_json() -> None:
    """Garbage response from the model returns None without raising."""
    from axi.reminder_brain import parse_when_brain

    with patch("axi.brain.ask", return_value="no entiendo, perdón"):
        result = parse_when_brain("cuando pueda", "America/Mexico_City")

    assert result is None


def test_parse_when_brain_returns_none_on_brain_error() -> None:
    """If brain.ask raises, the function swallows it and returns None."""
    from axi.reminder_brain import parse_when_brain

    with patch("axi.brain.ask", side_effect=TimeoutError("brain timed out")):
        result = parse_when_brain("después del almuerzo", "America/Mexico_City")

    assert result is None


def test_parse_when_brain_passes_now_and_tz_to_prompt() -> None:
    """The prompt sent to brain.ask contains the current time and the target tz."""
    from axi.reminder_brain import parse_when_brain

    captured_kwargs: dict = {}

    def _fake_ask(prompt: str, system: str = "", **kwargs):
        captured_kwargs["prompt"] = prompt
        captured_kwargs["system"] = system
        return json.dumps({"when_iso": None})

    with patch("axi.brain.ask", side_effect=_fake_ask):
        parse_when_brain("después del almuerzo", "America/Mexico_City")

    system = captured_kwargs.get("system", "")
    prompt = captured_kwargs.get("prompt", "")

    # System prompt must mention the timezone
    assert "America/Mexico_City" in system or "America/Mexico_City" in prompt
    # System prompt must have some time reference (year or current date marker)
    assert "2026" in system or "2026" in prompt
    # User prompt must contain the original when_text
    assert "almuerzo" in prompt


def test_system_prompt_instructs_null_for_non_temporal_text() -> None:
    """The prompt must tell the model to return null for non-temporal text so
    instructions like 'hacer las pruebas y borrarlas' don't become reminders."""
    from axi.reminder_brain import parse_when_brain

    captured: dict = {}

    def _fake_ask(prompt: str, system: str = "", **kwargs):
        captured["system"] = system
        return json.dumps({"when_iso": None})

    with patch("axi.brain.ask", side_effect=_fake_ask):
        parse_when_brain("hacer las pruebas y borrarlas", "America/Mexico_City")

    system = captured.get("system", "").lower()
    assert "null" in system
    # Must explicitly steer away from inventing/defaulting a time.
    assert "task" in system or "instruction" in system or "no real temporal" in system


def test_non_temporal_instruction_returns_none_when_brain_says_null() -> None:
    """End-to-end of the guard: a task instruction (the model returns null)
    yields no datetime, so parse_reminder won't create a bogus reminder."""
    from axi.reminder_brain import parse_when_brain

    with patch("axi.brain.ask", return_value=json.dumps({"when_iso": None})):
        result = parse_when_brain(
            "hacer tus pruebas y tus tests, pero borrarlos", "America/Mexico_City"
        )

    assert result is None
