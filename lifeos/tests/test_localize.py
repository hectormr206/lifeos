"""Tests for lifeos.localize."""

from __future__ import annotations

from datetime import datetime


def test_format_local_when_spanish() -> None:
    from lifeos.localize import format_local_when
    # Wednesday 2026-05-20 10:30 (note: weekday() = 2 for Wednesday)
    dt = datetime(2026, 5, 20, 10, 30)
    assert format_local_when(dt, "es-MX") == "miércoles 20 may 10:30"
    assert format_local_when(dt, "es") == "miércoles 20 may 10:30"


def test_format_local_when_english() -> None:
    from lifeos.localize import format_local_when
    dt = datetime(2026, 5, 20, 10, 30)
    assert format_local_when(dt, "en-US") == "Wednesday 20 May 10:30"


def test_format_local_when_defaults_to_spanish() -> None:
    from lifeos.localize import format_local_when
    dt = datetime(2026, 5, 20, 10, 30)
    assert format_local_when(dt, None) == "miércoles 20 may 10:30"


def test_msg_one_shot_spanish() -> None:
    from lifeos.localize import msg
    out = msg("reminder_one_shot", "es-MX", when="jueves 21 may 09:00", message="llamar")
    assert "Listo" in out
    assert "jueves 21 may 09:00" in out
    assert '"llamar"' in out


def test_msg_one_shot_english() -> None:
    from lifeos.localize import msg
    out = msg("reminder_one_shot", "en-US", when="Thursday 21 May 09:00", message="call")
    assert "Got it" in out
    assert "Thursday 21 May 09:00" in out


def test_msg_recurring_spanish() -> None:
    from lifeos.localize import msg
    out = msg("reminder_recurring", "es-MX",
              cron="0 9 * * *", when="mañana 09:00", message="agua")
    assert "recurrente" in out
    assert "0 9 * * *" in out


def test_msg_unknown_lang_falls_back_to_spanish() -> None:
    from lifeos.localize import msg
    out = msg("reminder_one_shot", "fr-FR", when="x", message="y")
    assert "Listo" in out
