"""Family subject attribution — stores, ingestion markers, stats isolation.

Convention: the person is stated at the START or END of the message
("Mi esposa tuvo 121, 79, 61 pulsos" / "108, 72, 66 pulsos de mi esposa").
Unmarked text belongs to the user (subject NULL).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "exercise.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "exercise.key"))
    from lifeos.exercise import store as ex_store
    from lifeos.health import store as h_store
    h_store.apply_migrations()
    ex_store.apply_migrations()
    yield


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ─── 1. Store round-trips ──────────────────────────────────────────────


def test_health_subject_roundtrip() -> None:
    from lifeos.health import entries
    e = entries.create(
        kind="vital", title="presión 121/79, pulso 61", when=_now(),
        data={"type": "blood_pressure", "systolic": 96, "diastolic": 82},
        subject="esposa",
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.subject == "esposa"


def test_health_subject_defaults_to_none() -> None:
    from lifeos.health import entries
    e = entries.create(kind="note", title="propio", when=_now())
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.subject is None


def test_exercise_subject_roundtrip() -> None:
    from lifeos.exercise import sessions
    s = sessions.create(
        kind="walk", title="caminata", duration_minutes=30, when=_now(),
        subject="esposa",
    )
    fetched = sessions.get(s.id)
    assert fetched is not None
    assert fetched.subject == "esposa"


def test_exercise_subject_defaults_to_none() -> None:
    from lifeos.exercise import sessions
    s = sessions.create(
        kind="walk", title="caminata", duration_minutes=30, when=_now(),
    )
    fetched = sessions.get(s.id)
    assert fetched is not None
    assert fetched.subject is None


# ─── 2. list_recent subject filtering ─────────────────────────────────


def _seed_health() -> None:
    from lifeos.health import entries
    entries.create(kind="note", title="mia", when=_now())
    entries.create(kind="note", title="de esposa", when=_now(), subject="esposa")
    entries.create(kind="note", title="de hija", when=_now(), subject="hija")


def test_health_list_recent_default_is_self_only() -> None:
    from lifeos.health import entries
    _seed_health()
    rows = entries.list_recent(days=7)
    assert [r.title for r in rows] == ["mia"]


def test_health_list_recent_subject_any_returns_all() -> None:
    from lifeos.health import entries
    _seed_health()
    rows = entries.list_recent(days=7, subject="any")
    assert {r.title for r in rows} == {"mia", "de esposa", "de hija"}


def test_health_list_recent_subject_name_filters() -> None:
    from lifeos.health import entries
    _seed_health()
    rows = entries.list_recent(days=7, subject="esposa")
    assert [r.title for r in rows] == ["de esposa"]


def test_exercise_list_recent_subject_filtering() -> None:
    from lifeos.exercise import sessions
    sessions.create(kind="walk", title="mia", duration_minutes=10, when=_now())
    sessions.create(kind="walk", title="de esposa", duration_minutes=20,
                    when=_now(), subject="esposa")
    assert [s.title for s in sessions.list_recent(days=7)] == ["mia"]
    assert {s.title for s in sessions.list_recent(days=7, subject="any")} == {
        "mia", "de esposa"}
    assert [s.title for s in sessions.list_recent(days=7, subject="esposa")] == [
        "de esposa"]


def test_exercise_summary_and_streak_exclude_family() -> None:
    from lifeos.exercise import sessions
    # Only family sessions exist → the user's own stats must stay at zero.
    sessions.create(kind="walk", title="de esposa", duration_minutes=30,
                    when=_now(), subject="esposa")
    s = sessions.summary(days=7)
    assert s["sessions_count"] == 0
    assert s["total_minutes"] == 0
    assert sessions.current_streak() == 0


# ─── 3. Ingestion: subject markers ─────────────────────────────────────


def test_parse_health_wife_pulse_real_case() -> None:
    """The real incident: 'Mi esposa tuvo 121, 79, 61 pulsos' was stored as
    the USER's 'pulso 96'. It must now parse exactly like the bare triple
    '121, 79, 61 pulsos' (presión 121/79 + pulso 61) with subject='esposa'."""
    from lifeos.health.ingestion import parse_health
    bare = parse_health("121, 79, 61 pulsos")
    assert bare is not None
    assert bare.kind == "vital"
    assert bare.data["type"] == "blood_pressure"
    assert (bare.data["systolic"], bare.data["diastolic"],
            bare.data["pulse_bpm"]) == (121, 79, 61)
    assert bare.subject is None

    marked = parse_health("Mi esposa tuvo 121, 79, 61 pulsos")
    assert marked is not None
    assert marked.kind == bare.kind
    assert marked.data == bare.data
    assert marked.title == bare.title
    assert marked.subject == "esposa"


def test_parse_health_trailing_marker() -> None:
    from lifeos.health.ingestion import parse_health
    hi = parse_health("108, 72, 66 pulsos de mi esposa")
    assert hi is not None
    assert hi.kind == "vital"
    assert hi.data["type"] == "blood_pressure"
    assert (hi.data["systolic"], hi.data["diastolic"], hi.data["pulse_bpm"]) == (
        108, 72, 66)
    assert hi.subject == "esposa"


def test_parse_health_leading_marker_named_vital() -> None:
    from lifeos.health.ingestion import parse_health
    hi = parse_health("Mi hija tiene fiebre 38.5")
    assert hi is not None
    assert hi.kind == "vital"
    assert hi.data["type"] == "temperature"
    assert hi.data["value"] == 38.5
    assert hi.subject == "hija"


def test_parse_health_en_marker() -> None:
    from lifeos.health.ingestion import parse_health
    hi = parse_health("My wife slept 7 hours")
    assert hi is not None
    assert hi.data["type"] == "sleep_hours"
    assert hi.data["value"] == 7
    assert hi.subject == "esposa"


def test_parse_health_relation_canonicalization() -> None:
    from lifeos.health.ingestion import parse_health
    hi = parse_health("Mi mujer tuvo 120, 80 y pulso 60")
    assert hi is not None
    assert hi.subject == "esposa"  # mujer → esposa (canonical)


def test_parse_health_unmarked_unchanged() -> None:
    from lifeos.health.ingestion import parse_health
    hi = parse_health("me duele la espalda")
    assert hi is not None
    assert hi.kind == "symptom"
    assert hi.subject is None


def test_parse_health_marker_without_parseable_remainder() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("Mi esposa fue al cine ayer") is None


def test_parse_health_mi_espalda_is_not_a_subject() -> None:
    """'mi espalda' must never be read as a family-subject marker."""
    from lifeos.health.ingestion import parse_health
    hi = parse_health("mi espalda me está doliendo mucho")
    if hi is not None:
        assert hi.subject is None


def test_parse_exercise_trailing_marker() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    ei = parse_exercise("30 min de cardio de mi esposa")
    assert ei is not None
    assert ei.kind == "cardio"
    assert ei.duration_minutes == 30
    assert ei.subject == "esposa"


def test_parse_exercise_leading_en_marker() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    ei = parse_exercise("My wife walked 30 min")
    assert ei is not None
    assert ei.kind == "walk"
    assert ei.duration_minutes == 30
    assert ei.subject == "esposa"


def test_parse_exercise_unmarked_unchanged() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    ei = parse_exercise("caminé 30 minutos")
    assert ei is not None
    assert ei.kind == "walk"
    assert ei.subject is None


# ─── 3b. detect_query_subject: free-form query classification ──────────


def test_detect_query_subject_mid_sentence_family() -> None:
    """Family-relation markers ANYWHERE in a free-form query are detected —
    the anchored detect_subject missed these mid-sentence phrasings."""
    from lifeos._common.subject import detect_query_subject
    assert detect_query_subject("¿cómo estaba mi esposa ayer?") == "esposa"
    assert detect_query_subject(
        "¿cuál es la presión de mi esposa esta semana?") == "esposa"
    assert detect_query_subject("dame la glucosa de mi esposa") == "esposa"


def test_detect_query_subject_canonicalizes_and_en() -> None:
    from lifeos._common.subject import detect_query_subject
    assert detect_query_subject("la presión de mi mujer hoy") == "esposa"
    assert detect_query_subject("how did my wife sleep") == "esposa"


def test_detect_query_subject_self_queries_return_none() -> None:
    """A self query with no relation word must NOT opt into family data."""
    from lifeos._common.subject import detect_query_subject
    assert detect_query_subject("¿cómo está mi presión?") is None
    assert detect_query_subject("resumen de salud") is None
    assert detect_query_subject("mi espalda me duele") is None
    assert detect_query_subject("") is None


# ─── 3c. search(): subject filtering (was leaking family data) ─────────


def test_search_defaults_to_self_only() -> None:
    from lifeos.health import entries
    entries.create(kind="vital", title="presión mía", when=_now())
    entries.create(kind="vital", title="presión de esposa", when=_now(),
                   subject="esposa")
    hits = entries.search("presión")
    assert [r.title for r in hits] == ["presión mía"]


def test_search_includes_family_when_subject_named() -> None:
    from lifeos.health import entries
    entries.create(kind="vital", title="presión mía", when=_now())
    entries.create(kind="vital", title="presión de esposa", when=_now(),
                   subject="esposa")
    hits = entries.search("presión", subject="esposa")
    assert [r.title for r in hits] == ["presión de esposa"]


# ─── 4. Stats isolation: digest + adaptive hour ────────────────────────


def test_digest_health_section_excludes_family() -> None:
    from lifeos.health import entries
    from lifeos.insights import digest
    entries.create(kind="vital", title="propio", when=_now(),
                   data={"type": "weight", "value": 64, "unit": "kg"})
    for _ in range(3):
        entries.create(kind="vital", title="de esposa", when=_now(),
                       data={"type": "heart_rate", "value": 60, "unit": "bpm"},
                       subject="esposa")
    section = digest._section_health(7)
    assert section is not None
    assert "1 vital(es)" in section


def test_adaptive_daily_hour_ignores_family_sleep() -> None:
    """Six family sleep vitals alone must NOT move the digest hour off the
    default — bedtimes at 17:00 CDMX would otherwise clamp it to 19:00."""
    from lifeos.health import entries
    from lifeos.insights import cron
    for i in range(6):
        # ts 07:00 UTC (wake) − 8h → bedtime 23:00 UTC = 17:00 CDMX.
        ts = (_now() - timedelta(days=i + 1)).replace(
            hour=7, minute=0, second=0, microsecond=0)
        entries.create(
            kind="vital", title="dormí 8h (esposa)", when=ts,
            data={"type": "sleep_hours", "value": 8, "unit": "h"},
            subject="esposa",
        )
    assert cron.adaptive_daily_hour() == (21, 0)
    # Sanity: the same data unmarked WOULD move the hour (guards against the
    # test passing for the wrong reason, e.g. a broken fixture).
    for i in range(6):
        ts = (_now() - timedelta(days=i + 1)).replace(
            hour=7, minute=0, second=0, microsecond=0)
        entries.create(
            kind="vital", title="dormí 8h", when=ts,
            data={"type": "sleep_hours", "value": 8, "unit": "h"},
        )
    assert cron.adaptive_daily_hour() == (19, 0)
