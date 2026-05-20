"""Tests for the exercise sessions DAO + sqlcipher store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "exercise.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "exercise.key"))
    from lifeos.exercise import store
    store.apply_migrations()
    yield


def test_db_is_encrypted() -> None:
    from lifeos.exercise import store, sessions
    sessions.create(
        kind="walk", title="paseo",
        duration_minutes=30, when=datetime.now(timezone.utc),
    )
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_session_roundtrip() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    s = sessions.create(
        kind="run", title="trote del parque",
        duration_minutes=35, intensity=7,
        mood_pre=5, mood_post=8,
        location="outdoor",
        data={"distance_km": 5.2, "pace_min_per_km": 6.7},
        tags=["mañana", "sol"],
        when=now,
    )
    fetched = sessions.get(s.id)
    assert fetched is not None
    assert fetched.kind == "run"
    assert fetched.duration_minutes == 35
    assert fetched.intensity == 7
    assert fetched.mood_delta == 3
    assert fetched.data["distance_km"] == 5.2
    assert fetched.tags == ["mañana", "sol"]


def test_rejects_bad_kind() -> None:
    from lifeos.exercise import sessions
    with pytest.raises(ValueError, match="kind"):
        sessions.create(
            kind="banana", title="x", duration_minutes=10,
            when=datetime.now(timezone.utc),
        )


def test_rejects_negative_duration() -> None:
    from lifeos.exercise import sessions
    with pytest.raises(ValueError, match="duration"):
        sessions.create(
            kind="walk", title="x", duration_minutes=-5,
            when=datetime.now(timezone.utc),
        )


def test_rejects_mood_out_of_range() -> None:
    from lifeos.exercise import sessions
    with pytest.raises(ValueError, match="mood"):
        sessions.create(
            kind="walk", title="x", duration_minutes=10,
            when=datetime.now(timezone.utc), mood_pre=15,
        )


def test_rejects_intensity_out_of_range() -> None:
    from lifeos.exercise import sessions
    with pytest.raises(ValueError, match="intensity"):
        sessions.create(
            kind="walk", title="x", duration_minutes=10,
            when=datetime.now(timezone.utc), intensity=0,
        )


def test_list_recent_sorted_desc() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    a = sessions.create(kind="walk", title="A", duration_minutes=20,
                        when=now - timedelta(days=2))
    b = sessions.create(kind="run", title="B", duration_minutes=15,
                        when=now - timedelta(hours=2))
    rows = sessions.list_recent(days=30)
    assert [r.id for r in rows] == [b.id, a.id]


def test_list_recent_filter_by_kind() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    w = sessions.create(kind="walk", title="A", duration_minutes=20, when=now)
    sessions.create(kind="run", title="B", duration_minutes=15, when=now)
    only_w = sessions.list_recent(days=30, kind="walk")
    assert {r.id for r in only_w} == {w.id}


def test_summary_aggregates() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    sessions.create(kind="walk", title="A", duration_minutes=30, when=now)
    sessions.create(kind="walk", title="B", duration_minutes=45, when=now)
    sessions.create(kind="run", title="C", duration_minutes=20, when=now)
    sessions.create(kind="strength", title="D", duration_minutes=60, when=now)

    s = sessions.summary(days=30)
    assert s["sessions_count"] == 4
    assert s["total_minutes"] == 155
    assert s["by_kind"]["walk"]["count"] == 2
    assert s["by_kind"]["walk"]["minutes"] == 75
    assert s["by_kind"]["run"]["count"] == 1


def test_streak_consecutive_days() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    # Yesterday, today
    sessions.create(kind="walk", title="A", duration_minutes=30, when=now - timedelta(days=1))
    sessions.create(kind="walk", title="B", duration_minutes=30, when=now)
    assert sessions.current_streak() == 2


def test_streak_broken_by_gap() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    # 3 days ago, then today — gap of 2 days
    sessions.create(kind="walk", title="A", duration_minutes=30, when=now - timedelta(days=3))
    sessions.create(kind="walk", title="B", duration_minutes=30, when=now)
    # Current streak counts back from today only.
    assert sessions.current_streak() == 1


def test_streak_zero_when_no_session_today() -> None:
    from lifeos.exercise import sessions
    now = datetime.now(timezone.utc)
    sessions.create(kind="walk", title="A", duration_minutes=30, when=now - timedelta(days=2))
    # No session today or yesterday → streak is 0.
    assert sessions.current_streak() == 0


def test_soft_delete() -> None:
    from lifeos.exercise import sessions
    s = sessions.create(kind="walk", title="x", duration_minutes=20,
                        when=datetime.now(timezone.utc))
    assert sessions.delete(s.id) is True
    assert sessions.get(s.id) is None
    assert all(r.id != s.id for r in sessions.list_recent(days=30))
