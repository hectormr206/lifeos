"""Tests for axi.reminder_brain.parse_reminder_brain — the LLM schedule fallback.

The brain is always mocked via the injectable `ask` callable so no real LLM or
network is hit. The function must NEVER raise: every failure mode returns None.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest

TZ = "America/Mexico_City"


def _ask_returning(payload):
    """Build a fake `ask` callable that returns `payload` (str or dict→json)."""
    raw = payload if isinstance(payload, str) else json.dumps(payload)

    def _ask(**kwargs):
        return raw

    return _ask


def test_agentic_recurring_happy_path() -> None:
    from axi.reminder_brain import parse_reminder_brain

    data = {
        "is_reminder": True,
        "kind": "agentic",
        "recurring": True,
        "cron": "0 8 * * *",
        "when_iso": None,
        "content": "las noticias",
    }
    ri = parse_reminder_brain(
        "tráeme las noticias todos los días", TZ, ask=_ask_returning(data)
    )

    assert ri is not None
    assert ri.action_kind == "agentic"
    assert ri.action_prompt == "las noticias"
    assert ri.message == "las noticias"
    assert ri.recurrence == "0 8 * * *"
    assert ri.when.tzinfo is not None


def test_message_one_shot_happy_path() -> None:
    from axi.reminder_brain import parse_reminder_brain

    future = (datetime.now(timezone.utc) + timedelta(days=1)).replace(microsecond=0)
    data = {
        "is_reminder": True,
        "kind": "message",
        "recurring": False,
        "cron": None,
        "when_iso": future.isoformat(),
        "content": "llamar al dentista",
    }
    ri = parse_reminder_brain("...", TZ, ask=_ask_returning(data))

    assert ri is not None
    assert ri.action_kind == "message"
    assert ri.action_prompt is None
    assert ri.recurrence is None
    assert ri.message == "llamar al dentista"
    assert ri.when.tzinfo is not None


def test_message_one_shot_handles_markdown_fences() -> None:
    from axi.reminder_brain import parse_reminder_brain

    future = (datetime.now(timezone.utc) + timedelta(hours=3)).replace(microsecond=0)
    data = {
        "is_reminder": True,
        "kind": "message",
        "recurring": False,
        "cron": None,
        "when_iso": future.isoformat(),
        "content": "sacar la basura",
    }
    wrapped = f"```json\n{json.dumps(data)}\n```"
    ri = parse_reminder_brain("...", TZ, ask=_ask_returning(wrapped))

    assert ri is not None
    assert ri.message == "sacar la basura"


def test_is_reminder_false_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    data = {
        "is_reminder": False,
        "kind": "message",
        "recurring": False,
        "cron": None,
        "when_iso": None,
        "content": "",
    }
    assert parse_reminder_brain("hola", TZ, ask=_ask_returning(data)) is None


def test_invalid_cron_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    data = {
        "is_reminder": True,
        "kind": "agentic",
        "recurring": True,
        "cron": "0 99 * * *",  # hour 99 — CronTrigger.from_crontab rejects it
        "when_iso": None,
        "content": "las noticias",
    }
    assert parse_reminder_brain("x", TZ, ask=_ask_returning(data)) is None


def test_non_five_field_cron_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    data = {
        "is_reminder": True,
        "kind": "agentic",
        "recurring": True,
        "cron": "daily",
        "when_iso": None,
        "content": "las noticias",
    }
    assert parse_reminder_brain("x", TZ, ask=_ask_returning(data)) is None


def test_naive_when_iso_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    data = {
        "is_reminder": True,
        "kind": "message",
        "recurring": False,
        "cron": None,
        "when_iso": "2026-12-01T09:00:00",  # no timezone offset → naive
        "content": "x",
    }
    assert parse_reminder_brain("x", TZ, ask=_ask_returning(data)) is None


def test_invalid_json_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    assert parse_reminder_brain("x", TZ, ask=_ask_returning("no entiendo")) is None


def test_brain_error_returns_none() -> None:
    from axi.reminder_brain import parse_reminder_brain

    def _boom(**kwargs):
        raise TimeoutError("brain timed out")

    assert parse_reminder_brain("x", TZ, ask=_boom) is None


def test_thinking_disabled_and_small_budget() -> None:
    from axi.reminder_brain import parse_reminder_brain

    captured: dict = {}

    def _ask(**kwargs):
        captured.update(kwargs)
        return json.dumps({"is_reminder": False})

    parse_reminder_brain("x", TZ, ask=_ask)

    assert captured.get("think") is False
    assert captured.get("max_tokens", 9999) <= 256
    # Current time + tz must be conveyed to the model.
    blob = (captured.get("system", "") + captured.get("prompt", "")).lower()
    assert TZ.lower() in blob
    assert "2026" in (captured.get("system", "") + captured.get("prompt", ""))


def test_default_ask_uses_brain(monkeypatch) -> None:
    """When `ask` is not injected, it defaults to axi.brain.ask (still mocked)."""
    from axi.reminder_brain import parse_reminder_brain
    from axi import brain

    data = {
        "is_reminder": True,
        "kind": "message",
        "recurring": False,
        "cron": None,
        "when_iso": (datetime.now(timezone.utc) + timedelta(days=1))
        .replace(microsecond=0)
        .isoformat(),
        "content": "regar las plantas",
    }
    monkeypatch.setattr(brain, "ask", lambda **kw: json.dumps(data))

    ri = parse_reminder_brain("recordame regar las plantas en algún momento", TZ)
    assert ri is not None
    assert ri.message == "regar las plantas"


def test_schedule_prompt_has_cron_rules_for_weekdays_and_ranges():
    """Guard the prompt guidance that fixed complex-cron errors: weekdays go in
    the day-of-week field (not day-of-month), and hour ranges use the hour field."""
    from axi.reminder_brain import _SCHEDULE_SYSTEM_TEMPLATE
    low = _SCHEDULE_SYSTEM_TEMPLATE.lower()
    assert "day-of-month" in low and "day-of-week" in low
    assert "1,4" in _SCHEDULE_SYSTEM_TEMPLATE   # multi-weekday example
    assert "9-18" in _SCHEDULE_SYSTEM_TEMPLATE  # hour-range example
