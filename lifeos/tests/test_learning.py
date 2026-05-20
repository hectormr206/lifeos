"""Tests for the learning entries DAO + encrypted store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learning.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learning.key"))
    from lifeos.learning import store
    store.apply_migrations()
    yield


def test_db_is_encrypted() -> None:
    from lifeos.learning import store, entries
    entries.create(kind="book", title="x", when=datetime.now(timezone.utc))
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_book_roundtrip() -> None:
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="book", title="Atomic Habits", author="James Clear",
        body="Notas del libro...", status="active",
        progress="cap 3/12", tags=["productividad", "hábitos"],
        when=now,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "book"
    assert fetched.author == "James Clear"
    assert fetched.status == "active"
    assert fetched.progress == "cap 3/12"
    assert fetched.tags == ["productividad", "hábitos"]


def test_create_idea_with_body() -> None:
    from lifeos.learning import entries
    e = entries.create(
        kind="idea", title="container-presentational pattern",
        body="Pensar si vale la pena aplicar esto al dashboard.",
        when=datetime.now(timezone.utc),
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "idea"


def test_create_rejects_bad_kind() -> None:
    from lifeos.learning import entries
    with pytest.raises(ValueError, match="kind"):
        entries.create(kind="totally_wrong", title="x",
                       when=datetime.now(timezone.utc))


def test_create_rejects_bad_status() -> None:
    from lifeos.learning import entries
    with pytest.raises(ValueError, match="status"):
        entries.create(kind="book", title="x", status="pending",
                       when=datetime.now(timezone.utc))


def test_create_rejects_rating_out_of_range() -> None:
    from lifeos.learning import entries
    with pytest.raises(ValueError, match="rating"):
        entries.create(kind="book", title="x", rating=15,
                       when=datetime.now(timezone.utc))


def test_list_recent_filter_by_status_and_kind() -> None:
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="book", title="A", status="active", when=now)
    b = entries.create(kind="book", title="B", status="done", when=now)
    entries.create(kind="course", title="C", status="active", when=now)
    entries.create(kind="idea", title="I", when=now)

    active_books = entries.list_recent(days=30, kind="book", status="active")
    assert {r.id for r in active_books} == {a.id}


def test_active_books_helper() -> None:
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="book", title="A", status="active", when=now)
    entries.create(kind="book", title="B", status="done", when=now)
    entries.create(kind="course", title="C", status="active", when=now)
    rows = entries.active_books()
    assert {r.id for r in rows} == {a.id}


def test_mark_done_sets_completed_at_and_rating() -> None:
    from lifeos.learning import entries
    e = entries.create(kind="book", title="x", status="active",
                       when=datetime.now(timezone.utc))
    entries.mark_done(e.id, rating=9)
    after = entries.get(e.id)
    assert after is not None
    assert after.status == "done"
    assert after.completed_at is not None
    assert after.rating == 9


def test_mark_done_rejects_invalid_rating() -> None:
    from lifeos.learning import entries
    e = entries.create(kind="book", title="x", status="active",
                       when=datetime.now(timezone.utc))
    with pytest.raises(ValueError, match="rating"):
        entries.mark_done(e.id, rating=0)


def test_search_finds_by_title_or_body_or_author() -> None:
    from lifeos.learning import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="book", title="Sapiens", author="Yuval Noah Harari", when=now)
    b = entries.create(kind="idea", title="x", body="pensamiento harari", when=now)
    c = entries.create(kind="course", title="otro", when=now)

    hits_author = entries.search("harari")
    assert {r.id for r in hits_author} == {a.id, b.id}

    hits_title = entries.search("Sapiens")
    assert {r.id for r in hits_title} == {a.id}


def test_soft_delete() -> None:
    from lifeos.learning import entries
    e = entries.create(kind="book", title="x",
                       when=datetime.now(timezone.utc))
    assert entries.delete(e.id) is True
    assert entries.get(e.id) is None
    assert all(r.id != e.id for r in entries.list_recent(days=30))


def test_update_progress() -> None:
    from lifeos.learning import entries
    e = entries.create(kind="book", title="x", status="active",
                       when=datetime.now(timezone.utc))
    entries.update_progress(e.id, progress="cap 7/12")
    after = entries.get(e.id)
    assert after is not None
    assert after.progress == "cap 7/12"
