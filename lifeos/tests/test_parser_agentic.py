"""Tests for parse_agentic_reminder (Briefings intent capture) — TDD.

Agentic triggers (tráeme/búscame/mándame …) that the static reminder parser
does not catch must be recognized as agentic recurring/one-shot tasks.
"""

from __future__ import annotations

from datetime import timezone


def test_parses_recurring_agentic_request() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder(
        "tráeme las 10 noticias tech del día todos los días a las 8"
    )

    assert intent is not None
    assert intent.action_kind == "agentic"
    assert intent.recurrence == "0 8 * * *"
    assert "noticias" in intent.action_prompt
    assert intent.when.tzinfo is not None
    assert intent.when.tzinfo == timezone.utc or intent.when.utcoffset() is not None


def test_buscame_clima_one_shot() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder("búscame el clima mañana a las 7")
    assert intent is not None
    assert intent.action_kind == "agentic"
    assert "clima" in intent.action_prompt


def test_plain_reminder_is_not_agentic() -> None:
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("recordame llamar al dentista mañana a las 9") is None


def test_casual_phrase_is_not_agentic() -> None:
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("dame un abrazo") is None
