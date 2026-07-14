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


def test_format_short_when_spanish() -> None:
    from lifeos.localize import format_short_when
    # Saturday 2026-05-23 14:00
    dt = datetime(2026, 5, 23, 14, 0)
    assert format_short_when(dt, "es-MX") == "sáb 23 14:00"
    assert format_short_when(dt, None) == "sáb 23 14:00"


def test_format_short_when_english() -> None:
    from lifeos.localize import format_short_when
    dt = datetime(2026, 5, 23, 14, 0)
    assert format_short_when(dt, "en-US") == "Sat 23 14:00"
    assert format_short_when(dt, "en") == "Sat 23 14:00"


def test_format_short_when_zero_pads_day() -> None:
    # strftime('%a %d %H:%M') zero-pads the day — the replacement must too.
    from lifeos.localize import format_short_when
    dt = datetime(2026, 6, 1, 9, 5)  # Monday
    assert format_short_when(dt, "es") == "lun 01 09:05"
    assert format_short_when(dt, "en") == "Mon 01 09:05"


def test_msg_reminder_created() -> None:
    from lifeos.localize import msg
    es = msg("reminder_created", "es-MX", message="llamar a mamá", when="sáb 23 14:00")
    assert es == "Recordatorio: llamar a mamá — sáb 23 14:00"
    en = msg("reminder_created", "en-US", message="call mom", when="Sat 23 14:00")
    assert en == "Reminder: call mom — Sat 23 14:00"


def test_msg_intent_executed() -> None:
    from lifeos.localize import msg
    assert msg("intent_executed", "es-MX", intent="open_dashboard") == (
        "Acción ejecutada: open_dashboard"
    )
    assert msg("intent_executed", "en-US", intent="open_dashboard") == (
        "Action executed: open_dashboard"
    )


def test_msg_camera_busy() -> None:
    from lifeos.localize import msg
    es = msg("camera_busy", "es", who="zoom")
    assert es == "📷 No puedo ver — la cámara la usa zoom (¿reunión activa?)"
    en = msg("camera_busy", "en", who="zoom")
    assert "zoom" in en and "camera" in en.lower()
    assert msg("camera_busy_other_app", "es") == "otra app"
    assert msg("camera_busy_other_app", "en") == "another app"


def test_msg_meeting_active() -> None:
    from lifeos.localize import msg
    assert msg("meeting_active", "es", mid=42) == "🎙️📷 Modo reunión activo (id #42)"
    en = msg("meeting_active", "en", mid=42)
    assert "Meeting mode active" in en and "#42" in en


def test_msg_dev_develop_keys() -> None:
    from lifeos.localize import msg
    assert msg("dev_no_goal", "es") == "No entendí qué quieres que desarrolle."
    assert msg("dev_no_goal", "en")  # exists and non-empty
    assert msg("dev_no_goal", "en") != msg("dev_no_goal", "es")
    assert msg("dev_env_created", "es") == (
        "Listo, lo armé como ambiente en Desarrollo — entra a /desarrollo "
        "para probarlo y desplegarlo."
    )
    assert "/desarrollo" in msg("dev_env_created", "en")
    assert msg("dev_env_created", "en") != msg("dev_env_created", "es")
    assert msg("dev_env_created_speak", "es") == (
        "Listo, lo armé como ambiente en Desarrollo. Entra a probarlo cuando quieras."
    )
    assert msg("dev_env_created_speak", "en") != msg("dev_env_created_speak", "es")
