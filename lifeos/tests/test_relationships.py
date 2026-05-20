"""Tests for the relationships DAO: people + interactions."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    from lifeos.relationships import store
    store.apply_migrations()
    yield


# ─── Encryption sanity ─────────────────────────────────────────────────

def test_db_is_encrypted() -> None:
    from lifeos.relationships import store, people
    people.create(name="María")
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


# ─── People DAO ────────────────────────────────────────────────────────

def test_create_person_roundtrip() -> None:
    from lifeos.relationships import people
    p = people.create(name="María", role="esposa", color="#ff6b9b")
    assert p.id
    assert p.name == "María"
    assert p.role == "esposa"
    assert p.color == "#ff6b9b"
    fetched = people.get(p.id)
    assert fetched is not None
    assert fetched.name == "María"


def test_find_by_name_case_insensitive() -> None:
    from lifeos.relationships import people
    p = people.create(name="María", role="esposa")
    assert people.find_by_name("maría").id == p.id
    assert people.find_by_name("MARÍA").id == p.id
    assert people.find_by_name("Maria") is None  # accents matter — exact match required


def test_get_or_create_idempotent() -> None:
    from lifeos.relationships import people
    p1 = people.get_or_create(name="Juan", role="amigo")
    p2 = people.get_or_create(name="Juan", role="amigo")
    assert p1.id == p2.id


def test_list_people_excludes_deleted() -> None:
    from lifeos.relationships import people
    a = people.create(name="A")
    b = people.create(name="B")
    people.delete(b.id)
    ids = {p.id for p in people.list_all()}
    assert ids == {a.id}


# ─── Interactions DAO ──────────────────────────────────────────────────

def test_create_interaction_roundtrip() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="María")
    now = datetime.now(timezone.utc)
    i = interactions.create(
        person_id=p.id, kind="conversation",
        title="charla rápida sobre la semana",
        when=now, mood_pre=6, mood_post=8, tags=["positiva"],
    )
    fetched = interactions.get(i.id)
    assert fetched is not None
    assert fetched.kind == "conversation"
    assert fetched.mood_pre == 6
    assert fetched.mood_post == 8
    assert fetched.tags == ["positiva"]


def test_create_interaction_rejects_bad_kind() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="A")
    with pytest.raises(ValueError, match="kind"):
        interactions.create(
            person_id=p.id, kind="banana", title="x",
            when=datetime.now(timezone.utc),
        )


def test_create_interaction_rejects_unknown_person() -> None:
    from lifeos.relationships import interactions
    with pytest.raises(ValueError, match="person"):
        interactions.create(
            person_id="nonexistent-ulid", kind="note", title="x",
            when=datetime.now(timezone.utc),
        )


def test_create_interaction_rejects_mood_out_of_range() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="x")
    with pytest.raises(ValueError, match="mood"):
        interactions.create(
            person_id=p.id, kind="note", title="x",
            when=datetime.now(timezone.utc), mood_pre=15,
        )


def test_timeline_by_person_sorted_desc() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="María")
    now = datetime.now(timezone.utc)
    older = interactions.create(person_id=p.id, kind="call", title="A", when=now - timedelta(days=2))
    newer = interactions.create(person_id=p.id, kind="call", title="B", when=now - timedelta(hours=1))
    rows = interactions.timeline_for(p.id)
    assert [r.id for r in rows] == [newer.id, older.id]


def test_recent_interactions_across_people() -> None:
    from lifeos.relationships import people, interactions
    a = people.create(name="A")
    b = people.create(name="B")
    now = datetime.now(timezone.utc)
    interactions.create(person_id=a.id, kind="note", title="x", when=now - timedelta(days=1))
    interactions.create(person_id=b.id, kind="note", title="y", when=now)
    rows = interactions.list_recent(days=30)
    assert len(rows) == 2
    # Newest first
    assert rows[0].person_id == b.id


def test_conflicts_only_filter() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="x")
    now = datetime.now(timezone.utc)
    interactions.create(person_id=p.id, kind="conversation", title="a", when=now)
    c1 = interactions.create(person_id=p.id, kind="conflict", title="b", when=now)
    rows = interactions.list_recent(days=30, kind="conflict")
    assert {r.id for r in rows} == {c1.id}


def test_mood_delta_helper() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="x")
    now = datetime.now(timezone.utc)
    i = interactions.create(
        person_id=p.id, kind="quality_time", title="paseo",
        when=now, mood_pre=4, mood_post=8,
    )
    assert i.mood_delta == 4
    i2 = interactions.create(
        person_id=p.id, kind="conflict", title="discusión",
        when=now, mood_pre=7, mood_post=3,
    )
    assert i2.mood_delta == -4


def test_soft_delete() -> None:
    from lifeos.relationships import people, interactions
    p = people.create(name="x")
    i = interactions.create(person_id=p.id, kind="note", title="x", when=datetime.now(timezone.utc))
    assert interactions.delete(i.id) is True
    assert interactions.timeline_for(p.id) == []
