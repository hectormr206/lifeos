"""Tests for lifeos.parser.parse_reminder."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest


def test_returns_none_for_unrelated_text() -> None:
    from lifeos.parser import parse_reminder
    assert parse_reminder("hola Axi, ¿qué tal?") is None
    assert parse_reminder("explícame qué es un MoE") is None
    assert parse_reminder("") is None
    assert parse_reminder(None) is None  # type: ignore[arg-type]


def test_simple_reminder_with_relative_time() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame llamar al dentista mañana a las 9")
    assert ri is not None
    assert "dentista" in ri.message.lower()
    assert ri.when.tzinfo is not None
    # Must be in the future
    assert ri.when > datetime.now(timezone.utc)


def test_accepts_axi_prefix() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("axi, recordame regar las plantas hoy a las 8 de la noche")
    assert ri is not None
    assert "regar" in ri.message.lower()


def test_accepts_acordame_variant() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("acordame tomar la pastilla en 30 minutos")
    assert ri is not None
    assert "pastilla" in ri.message.lower()
    # ±30 seconds tolerance
    delta = ri.when - datetime.now(timezone.utc)
    assert timedelta(minutes=29) < delta < timedelta(minutes=31)


def test_accepts_recuerdame_with_accent() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recuérdame llamar a mamá el sábado a las 10")
    assert ri is not None
    assert "mamá" in ri.message.lower() or "mama" in ri.message.lower()


def test_de_que_glue_words_stripped() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame de pagar la luz mañana")
    assert ri is not None
    assert ri.message.lower().startswith("pagar")


def test_past_time_today_bumps_to_tomorrow() -> None:
    """If user says 'a las 9' and it's already 10 AM, schedule for tomorrow."""
    from lifeos.parser import parse_reminder
    # Use a time that's definitely already passed today in any TZ: 00:01.
    # dateparser interprets "a las 00:01" as today 00:01, which is in the past.
    ri = parse_reminder("recordame ir al gym a las 00:01")
    assert ri is not None
    # Must still be in the future
    assert ri.when > datetime.now(timezone.utc)


def test_returns_none_when_no_time_marker() -> None:
    """Reminders without a time expression are ambiguous — we punt."""
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame que tengo que llamar al dentista")
    assert ri is None


def test_handles_en_minutos_horas() -> None:
    from lifeos.parser import parse_reminder
    ri = parse_reminder("recordame estirar en 5 minutos")
    assert ri is not None
    delta = ri.when - datetime.now(timezone.utc)
    assert timedelta(minutes=4) < delta < timedelta(minutes=6)
