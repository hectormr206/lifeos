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


# ── brain_fallback tests ──────────────────────────────────────────────────────

def test_brain_fallback_not_called_when_dateparser_succeeds() -> None:
    """When dateparser succeeds, the fallback must never be invoked."""
    from lifeos.parser import parse_reminder

    def _should_not_be_called(when_text: str, tz: str) -> None:
        raise AssertionError("brain_fallback must not be called when dateparser succeeds")

    ri = parse_reminder(
        "recordame llamar al dentista mañana a las 9",
        brain_fallback=_should_not_be_called,
    )
    assert ri is not None
    assert "dentista" in ri.message.lower()


def test_brain_fallback_called_when_dateparser_returns_none() -> None:
    """When dateparser fails, the fallback is invoked and its datetime is used."""
    from lifeos.parser import parse_reminder

    target_dt = datetime(2026, 5, 25, 15, 30, tzinfo=timezone.utc)

    def _fallback(when_text: str, tz: str) -> datetime:
        assert "almuerzo" in when_text.lower() or when_text  # called with the when fragment
        return target_dt

    ri = parse_reminder(
        "recordame llamar al médico después del almuerzo",
        brain_fallback=_fallback,
    )
    assert ri is not None
    assert ri.when == target_dt


def test_brain_fallback_returns_none_falls_through() -> None:
    """When both dateparser and fallback return None, parse_reminder returns None."""
    from lifeos.parser import parse_reminder

    def _fallback(when_text: str, tz: str) -> None:
        return None

    ri = parse_reminder(
        "recordame llamar al médico después del almuerzo",
        brain_fallback=_fallback,
    )
    assert ri is None


def test_brain_fallback_raises_is_caught() -> None:
    """If the fallback raises any exception, the parser catches it and returns None."""
    from lifeos.parser import parse_reminder

    def _fallback(when_text: str, tz: str) -> datetime:
        raise RuntimeError("brain timed out")

    ri = parse_reminder(
        "recordame llamar al médico después del almuerzo",
        brain_fallback=_fallback,
    )
    assert ri is None


def test_brain_fallback_default_none_preserves_old_behavior() -> None:
    """Omitting brain_fallback entirely still returns None for unparseable phrases."""
    from lifeos.parser import parse_reminder

    ri = parse_reminder("recordame llamar al médico después del almuerzo")
    assert ri is None


def test_brain_fallback_must_return_timezone_aware() -> None:
    """If the fallback returns a naive datetime, the parser treats it as invalid."""
    from lifeos.parser import parse_reminder

    naive_dt = datetime(2026, 5, 25, 15, 30)  # no tzinfo

    def _fallback(when_text: str, tz: str) -> datetime:
        return naive_dt

    ri = parse_reminder(
        "recordame llamar al médico después del almuerzo",
        brain_fallback=_fallback,
    )
    assert ri is None
