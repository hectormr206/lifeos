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


def test_natural_quiero_que_me_mandes_with_url_defaults_to_8am() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder(
        "Quiero que todos los días me mandes las últimas 10 noticias más "
        "relevantes de https://news.ycombinator.com/"
    )
    assert intent is not None
    assert intent.action_kind == "agentic"
    assert intent.recurrence == "0 8 * * *"
    assert "noticias" in intent.action_prompt
    assert "news.ycombinator.com" in intent.action_prompt
    assert intent.when.tzinfo is not None


def test_mandame_resumen_explicit_hour() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder("mándame un resumen de IA todos los días a las 7")
    assert intent is not None
    assert intent.action_kind == "agentic"
    assert intent.recurrence == "0 7 * * *"
    assert "resumen" in intent.action_prompt


def test_diariamente_without_hour_defaults_to_8am() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder("diariamente tráeme el clima")
    assert intent is not None
    assert intent.action_kind == "agentic"
    assert intent.recurrence == "0 8 * * *"
    assert "clima" in intent.action_prompt


def test_necesito_que_cada_dia_defaults_to_8am() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder(
        "necesito que cada día me mandes las novedades de tecnología"
    )
    assert intent is not None
    assert intent.action_kind == "agentic"
    assert intent.recurrence == "0 8 * * *"
    assert "novedades" in intent.action_prompt


def test_static_reminder_stays_non_agentic() -> None:
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("recordame sacar la basura mañana") is None


def test_greeting_is_not_agentic() -> None:
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("hola Axi") is None


def test_recurring_daily_with_explicit_hour_still_works() -> None:
    from lifeos.parser import parse_agentic_reminder

    intent = parse_agentic_reminder("tráeme las noticias todos los días a las 8")
    assert intent is not None
    assert intent.recurrence == "0 8 * * *"


def test_daily_hour_detected_when_separated_from_recurrence():
    """Regression for the real bug: 'todos los días ... a las 9 am' must
    schedule 09:00, not default to 08:00, even though 'todos los días' and the
    hour are far apart in the sentence."""
    from lifeos.parser import parse_agentic_reminder

    r = parse_agentic_reminder(
        "Quiero que todos los dias me mandes las ultimas 10 noticias de "
        "https://news.ycombinator.com/ a las 9 am"
    )
    assert r is not None
    assert r.recurrence == "0 9 * * *"


def test_daily_hour_am_pm_and_minutes():
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("todos los días tráeme el clima a las 9 pm").recurrence == "0 21 * * *"
    assert parse_agentic_reminder("diariamente tráeme noticias a las 9:30").recurrence == "30 9 * * *"
    assert parse_agentic_reminder("todos los días tráeme las noticias a las 7 am").recurrence == "0 7 * * *"


def test_daily_without_any_hour_defaults_to_8():
    from lifeos.parser import parse_agentic_reminder
    assert parse_agentic_reminder("todos los días tráeme el clima").recurrence == "0 8 * * *"


# ── English support (Wave 2) ─────────────────────────────────────────────────


def test_agentic_en_bring_tech_news_every_morning() -> None:
    from lifeos.parser import parse_agentic_reminder

    r = parse_agentic_reminder("bring me the tech news every morning at 9")
    assert r is not None
    assert r.action_kind == "agentic"
    assert r.recurrence == "0 9 * * *"
    assert "news" in r.action_prompt.lower()


def test_agentic_en_send_weather_daily() -> None:
    from lifeos.parser import parse_agentic_reminder

    r = parse_agentic_reminder("send me the weather every day at 7am")
    assert r is not None
    assert r.action_kind == "agentic"
    assert r.recurrence == "0 7 * * *"
    assert "weather" in r.action_prompt.lower()


def test_agentic_en_get_headlines_one_shot() -> None:
    from lifeos.parser import parse_agentic_reminder

    r = parse_agentic_reminder("get me the headlines tomorrow at 8")
    assert r is not None
    assert r.action_kind == "agentic"
    assert r.recurrence is None
    assert "headlines" in r.action_prompt.lower()
    assert r.when.tzinfo is not None


def test_agentic_en_negative_no_content_signal() -> None:
    """A delivery verb without a content noun must not become a task."""
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("bring me a coffee tomorrow") is None


def test_agentic_en_negative_no_schedule() -> None:
    """Content without any recurrence or time marker is just chatter."""
    from lifeos.parser import parse_agentic_reminder

    assert parse_agentic_reminder("send me the news") is None
