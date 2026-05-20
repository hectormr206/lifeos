"""Tests for the insights pipeline (P6.1).

Patterns are pure functions over the domain DAOs. The digest composer
calls them + raw counts. Tests seed minimal data and assert the right
messages appear.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point every encrypted store at tmp_path."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "ex.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "ex.key"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit.key"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learn.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learn.key"))
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", str(tmp_path / "ev.db"))
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", str(tmp_path / "ev.key"))

    from lifeos import store as core_store
    from lifeos.health import store as h_store
    from lifeos.finance import store as f_store
    from lifeos.relationships import store as r_store
    from lifeos.exercise import store as e_store
    from lifeos.spirituality import store as s_store
    from lifeos.learning import store as l_store
    from lifeos.events import store as ev_store
    core_store.apply_migrations()
    h_store.apply_migrations()
    f_store.apply_migrations()
    r_store.apply_migrations()
    e_store.apply_migrations()
    s_store.apply_migrations()
    l_store.apply_migrations()
    ev_store.apply_migrations()
    yield


# ─── Patterns ─────────────────────────────────────────────────────────


def test_broken_exercise_streak_detected() -> None:
    from datetime import timezone as _tz
    from lifeos.exercise import sessions
    from lifeos.insights.patterns import broken_exercise_streak

    now = datetime.now(_tz.utc)
    # 4-day streak ending 3 days ago
    for i in range(3, 7):
        sessions.create(
            kind="walk", title=f"day-{i}",
            duration_minutes=30, when=now - timedelta(days=i),
        )
    # No session today
    p = broken_exercise_streak()
    assert p is not None
    assert p.kind == "broken_streak"
    assert "racha" in p.message.lower()


def test_no_streak_break_when_streak_active() -> None:
    from datetime import timezone as _tz
    from lifeos.exercise import sessions
    from lifeos.insights.patterns import broken_exercise_streak

    now = datetime.now(_tz.utc)
    sessions.create(kind="walk", title="today", duration_minutes=30, when=now)
    assert broken_exercise_streak() is None


def test_seasonal_recurrence_two_years() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries
    from lifeos.insights.patterns import seasonal_symptom_recurrence

    now = datetime.now(_tz.utc)
    # Same month-of-year twice in past years
    he_a = now.replace(year=now.year - 1)
    he_b = now.replace(year=now.year - 2)
    entries.create(kind="symptom", title="dolor garganta",
                   when=he_a, data={"location": "garganta"})
    entries.create(kind="symptom", title="dolor garganta",
                   when=he_b, data={"location": "garganta"})

    p = seasonal_symptom_recurrence(lookback_years=3, lookahead_days=45)
    assert p is not None
    assert "garganta" in p.message.lower()
    assert "patrón estacional" in p.message.lower() or "patron estacional" in p.message.lower()


def test_recurring_conflicts_detected() -> None:
    from datetime import timezone as _tz
    from lifeos.relationships import interactions, people
    from lifeos.insights.patterns import recurring_conflicts

    now = datetime.now(_tz.utc)
    p = people.create(name="Juan")
    interactions.create(person_id=p.id, kind="conflict", title="A", when=now - timedelta(days=10))
    interactions.create(person_id=p.id, kind="conflict", title="B", when=now - timedelta(days=2))
    interactions.create(person_id=p.id, kind="conflict", title="C", when=now)

    pat = recurring_conflicts(days=30, threshold=2)
    assert pat is not None
    assert "Juan" in pat.message


def test_sleep_deficit_when_avg_low() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries
    from lifeos.insights.patterns import sleep_deficit

    now = datetime.now(_tz.utc)
    for hours, days_ago in [(5.0, 1), (5.5, 2), (6.0, 3)]:
        entries.create(kind="vital", title=f"dormi {hours}h",
                       data={"type": "sleep_hours", "value": hours, "unit": "h"},
                       when=now - timedelta(days=days_ago))

    p = sleep_deficit(days=7, min_avg_hours=6.5)
    assert p is not None
    assert "durmiendo" in p.message.lower()


def test_sleep_deficit_no_alert_when_avg_ok() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries
    from lifeos.insights.patterns import sleep_deficit

    now = datetime.now(_tz.utc)
    for hours, days_ago in [(7.0, 1), (8.0, 2), (7.5, 3)]:
        entries.create(kind="vital", title=f"dormi {hours}h",
                       data={"type": "sleep_hours", "value": hours, "unit": "h"},
                       when=now - timedelta(days=days_ago))
    assert sleep_deficit(days=7, min_avg_hours=6.5) is None


def test_spending_acceleration_detected() -> None:
    from datetime import timezone as _tz
    from lifeos.finance import entries as fe
    from lifeos.insights.patterns import spending_acceleration

    now = datetime.now(_tz.utc)
    # Last 7 days: $3000 of expenses
    fe.create(kind="expense", title="A", amount=3000,
              when=now - timedelta(days=3))
    # Days 8-14: $500
    fe.create(kind="expense", title="B", amount=500,
              when=now - timedelta(days=10))

    p = spending_acceleration(days=14, ratio=1.5)
    assert p is not None
    assert "gastaste" in p.message.lower()


# ─── Digest composer ──────────────────────────────────────────────────


def test_empty_digest_when_no_data() -> None:
    from lifeos.insights.digest import compose
    d = compose(cadence="daily")
    assert d.sections_count == 0
    assert d.patterns_count == 0
    assert "actividad" in d.body.lower() or "registraste" in d.body.lower()


def test_digest_includes_health_section() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries
    from lifeos.insights.digest import compose

    entries.create(kind="symptom", title="dolor de cabeza",
                   when=datetime.now(_tz.utc))
    d = compose(cadence="daily")
    assert "salud" in d.body.lower()
    assert d.sections_count >= 1


def test_digest_includes_patterns_block() -> None:
    """If a pattern fires, the digest body should include it."""
    from datetime import timezone as _tz
    from lifeos.relationships import interactions, people
    from lifeos.insights.digest import compose

    now = datetime.now(_tz.utc)
    p = people.create(name="Carlos")
    interactions.create(person_id=p.id, kind="conflict", title="A",
                        when=now - timedelta(days=5))
    interactions.create(person_id=p.id, kind="conflict", title="B",
                        when=now - timedelta(days=2))

    d = compose(cadence="weekly")
    assert d.patterns_count >= 1
    assert "patrones detectados" in d.body.lower()
    assert "Carlos" in d.body
