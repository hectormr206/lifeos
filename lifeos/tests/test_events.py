"""Tests for the events DAO + encrypted store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", str(tmp_path / "events.db"))
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", str(tmp_path / "events.key"))
    from lifeos.events import store
    store.apply_migrations()
    yield


def test_db_is_encrypted() -> None:
    from lifeos.events import store, entries
    entries.create(kind="birthday", title="x", when=datetime.now(timezone.utc))
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_birthday_roundtrip() -> None:
    from lifeos.events import entries
    when = datetime(2026, 6, 8, 0, 0, 0, tzinfo=timezone.utc)
    e = entries.create(
        kind="birthday", title="Cumple papá",
        when=when, people=["papá"], tags=["familia"],
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "birthday"
    assert fetched.people == ["papá"]
    assert fetched.tags == ["familia"]
    assert fetched.is_upcoming is (when > datetime.now(timezone.utc))


def test_create_rejects_bad_kind() -> None:
    from lifeos.events import entries
    with pytest.raises(ValueError, match="kind"):
        entries.create(kind="totally_wrong", title="x",
                       when=datetime.now(timezone.utc))


def test_create_rejects_naive_when() -> None:
    from lifeos.events import entries
    with pytest.raises(ValueError, match="tz-aware"):
        entries.create(kind="party", title="x",
                       when=datetime(2026, 5, 20, 9, 0))


def test_is_upcoming_property() -> None:
    from lifeos.events import entries
    now = datetime.now(timezone.utc)
    future = entries.create(kind="meeting", title="future",
                            when=now + timedelta(days=2))
    past = entries.create(kind="meeting", title="past",
                          when=now - timedelta(days=2))
    assert future.is_upcoming is True
    assert past.is_upcoming is False


def test_upcoming_helper_returns_future_sorted_asc() -> None:
    from lifeos.events import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="meeting", title="A", when=now + timedelta(days=5))
    b = entries.create(kind="meeting", title="B", when=now + timedelta(days=1))
    c = entries.create(kind="meeting", title="C", when=now + timedelta(days=3))
    entries.create(kind="meeting", title="past", when=now - timedelta(days=1))
    rows = entries.upcoming(days_ahead=30)
    assert [r.id for r in rows] == [b.id, c.id, a.id]


def test_past_helper_returns_past_sorted_desc() -> None:
    from lifeos.events import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="party", title="A", when=now - timedelta(days=5))
    b = entries.create(kind="party", title="B", when=now - timedelta(days=1))
    c = entries.create(kind="party", title="C", when=now - timedelta(days=3))
    entries.create(kind="party", title="future", when=now + timedelta(days=1))
    rows = entries.past(days_back=30)
    assert [r.id for r in rows] == [b.id, c.id, a.id]


def test_list_recent_window_around_now() -> None:
    """list_recent returns BOTH upcoming and past within a window."""
    from lifeos.events import entries
    now = datetime.now(timezone.utc)
    fut = entries.create(kind="meeting", title="fut", when=now + timedelta(days=3))
    pst = entries.create(kind="meeting", title="pst", when=now - timedelta(days=3))
    rows = entries.list_recent(days_back=10, days_ahead=10)
    ids = {r.id for r in rows}
    assert {fut.id, pst.id}.issubset(ids)


def test_attach_reminder_id_persists() -> None:
    from lifeos.events import entries
    e = entries.create(
        kind="birthday", title="x", when=datetime.now(timezone.utc),
        reminder_id="01ABCREMINDER",
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.reminder_id == "01ABCREMINDER"


def test_search_by_title_and_people() -> None:
    from lifeos.events import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="birthday", title="Cumple papá", when=now, people=["papá"])
    b = entries.create(kind="meeting", title="Reunión 1:1", when=now, people=["María"])

    hits = entries.search("papá")
    assert {r.id for r in hits} == {a.id}
    hits = entries.search("María")
    assert {r.id for r in hits} == {b.id}


def test_soft_delete() -> None:
    from lifeos.events import entries
    e = entries.create(kind="party", title="x",
                       when=datetime.now(timezone.utc))
    assert entries.delete(e.id) is True
    assert entries.get(e.id) is None
