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
    from freezegun import freeze_time
    from lifeos.parser import parse_reminder

    target_dt = datetime(2026, 5, 25, 15, 30, tzinfo=timezone.utc)

    def _fallback(when_text: str, tz: str) -> datetime:
        assert "almuerzo" in when_text.lower() or when_text  # called with the when fragment
        return target_dt

    # Freeze the clock to early morning UTC so target_dt (15:30 UTC) is always
    # in the future — prevents parse_reminder's past-check from shifting +1 day.
    with freeze_time("2026-05-25 08:00:00"):
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


def test_relative_time_markers_split_message_correctly() -> None:
    """The 'después de', 'cuando', 'tras' markers should split message from when_text
    so the brain receives only the time fragment, not the whole rest.
    """
    from lifeos.parser import parse_reminder

    captured: dict[str, str] = {}
    target_dt = datetime(2026, 5, 25, 15, 30, tzinfo=timezone.utc)

    def _fallback(when_text: str, tz: str) -> datetime:
        captured["when_text"] = when_text
        return target_dt

    ri = parse_reminder(
        "Axi, recuérdame llamar a mamá después de comer",
        brain_fallback=_fallback,
    )
    assert ri is not None
    assert ri.message == "llamar a mamá"
    assert captured["when_text"].startswith("después de"), captured

    ri2 = parse_reminder(
        "recordame ir al gym cuando termine la reunión",
        brain_fallback=_fallback,
    )
    assert ri2 is not None
    assert ri2.message == "ir al gym"
    assert captured["when_text"].startswith("cuando"), captured


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


# ── English support (Wave 2) ─────────────────────────────────────────────────


def test_reminder_en_tomorrow_at_3pm() -> None:
    """EN word order puts the time FIRST — leading-when split must handle it."""
    from zoneinfo import ZoneInfo

    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me tomorrow at 3pm to call the dentist")
    assert ri is not None
    assert "dentist" in ri.message.lower()
    assert ri.recurrence is None
    assert ri.when > datetime.now(timezone.utc)
    local = ri.when.astimezone(ZoneInfo("America/Mexico_City"))
    assert local.hour == 15


def test_reminder_en_every_day_9am() -> None:
    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me every day at 9am to take my meds")
    assert ri is not None
    assert ri.recurrence == "0 9 * * *"
    assert "meds" in ri.message.lower()


def test_reminder_en_dont_forget_on_friday() -> None:
    from zoneinfo import ZoneInfo

    from lifeos.parser import parse_reminder

    ri = parse_reminder("don't forget the meeting on friday at 10am")
    assert ri is not None
    assert "meeting" in ri.message.lower()
    local = ri.when.astimezone(ZoneInfo("America/Mexico_City"))
    assert local.hour == 10
    assert local.weekday() == 4  # Friday


def test_reminder_en_in_minutes() -> None:
    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me to stretch in 5 minutes")
    assert ri is not None
    assert "stretch" in ri.message.lower()
    delta = ri.when - datetime.now(timezone.utc)
    assert timedelta(minutes=4) < delta < timedelta(minutes=6)


def test_reminder_en_every_weekday() -> None:
    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me every monday at 9 to stretch")
    assert ri is not None
    assert ri.recurrence == "0 9 * * 1"
    assert "stretch" in ri.message.lower()


def test_reminder_en_half_past_idiom() -> None:
    from zoneinfo import ZoneInfo

    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me to check the oven tomorrow at half past 8")
    assert ri is not None
    assert "oven" in ri.message.lower()
    local = ri.when.astimezone(ZoneInfo("America/Mexico_City"))
    assert (local.hour, local.minute) == (8, 30)


def test_reminder_en_quarter_to_idiom() -> None:
    from zoneinfo import ZoneInfo

    from lifeos.parser import parse_reminder

    ri = parse_reminder("remind me to leave tomorrow at quarter to 9")
    assert ri is not None
    local = ri.when.astimezone(ZoneInfo("America/Mexico_City"))
    assert (local.hour, local.minute) == (8, 45)


def test_reminder_en_negative_no_time_marker() -> None:
    from lifeos.parser import parse_reminder

    assert parse_reminder("remind me that I have to call the dentist") is None


def test_reminder_en_negative_casual_tell_me() -> None:
    from lifeos.parser import parse_reminder

    assert parse_reminder("tell me about your day") is None


def test_reminder_en_negative_not_a_trigger() -> None:
    """The trigger is anchored at the start — mid-sentence phrasing must not fire."""
    from lifeos.parser import parse_reminder

    assert parse_reminder("I told you not to forget things") is None


# looks_schedulish — EN markers must feed the LLM-fallback gate consistently.


def test_looks_schedulish_en_true() -> None:
    from lifeos.parser import looks_schedulish

    assert looks_schedulish("remind me tomorrow") is True
    assert looks_schedulish("every day at 9am") is True
    assert looks_schedulish("bring me the news daily") is True
    assert looks_schedulish("the report at 8:30") is True


def test_looks_schedulish_en_false() -> None:
    from lifeos.parser import looks_schedulish

    assert looks_schedulish("what a day") is False
    assert looks_schedulish("nothing much, thanks") is False
