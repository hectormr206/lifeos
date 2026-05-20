"""Tests for the spirituality entries DAO + encrypted store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit.key"))
    from lifeos.spirituality import store
    store.apply_migrations()
    yield


def test_db_is_encrypted() -> None:
    from lifeos.spirituality import store, entries
    entries.create(kind="reflection", title="x", when=datetime.now(timezone.utc))
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_reflection_roundtrip() -> None:
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="reflection",
        title="querer X sin sentirme atado",
        body="Estoy notando que la idea de querer X me genera ansiedad...",
        mood=6,
        tags=["semanal", "valores"],
        when=now,
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "reflection"
    assert "X" in fetched.title
    assert fetched.mood == 6
    assert fetched.tags == ["semanal", "valores"]


def test_create_gratitude_with_items_in_data() -> None:
    from lifeos.spirituality import entries
    e = entries.create(
        kind="gratitude",
        title="Agradezco hoy",
        body="3 cosas",
        data={"items": ["mi salud", "mi pareja", "el café de la mañana"]},
        when=datetime.now(timezone.utc),
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.data["items"] == ["mi salud", "mi pareja", "el café de la mañana"]


def test_create_retro_with_structure() -> None:
    from lifeos.spirituality import entries
    e = entries.create(
        kind="retro",
        title="Retro semanal 2026-W20",
        body="reflexión sobre la semana",
        data={
            "wins": ["terminé el proyecto X", "salí a caminar 4 veces"],
            "losses": ["no llamé a mamá"],
            "next_focus": "decir que no a cosas que no me importan",
        },
        when=datetime.now(timezone.utc),
    )
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.data["next_focus"] == "decir que no a cosas que no me importan"
    assert len(fetched.data["wins"]) == 2


def test_create_rejects_bad_kind() -> None:
    from lifeos.spirituality import entries
    with pytest.raises(ValueError, match="kind"):
        entries.create(kind="totally_invalid", title="x",
                        when=datetime.now(timezone.utc))


def test_create_rejects_naive_when() -> None:
    from lifeos.spirituality import entries
    with pytest.raises(ValueError, match="tz-aware"):
        entries.create(kind="reflection", title="x",
                       when=datetime(2026, 5, 20, 9, 0, 0))


def test_create_rejects_mood_out_of_range() -> None:
    from lifeos.spirituality import entries
    with pytest.raises(ValueError, match="mood"):
        entries.create(kind="reflection", title="x", mood=15,
                       when=datetime.now(timezone.utc))


def test_list_recent_sorted_desc_by_ts() -> None:
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="reflection", title="A", when=now - timedelta(days=2))
    b = entries.create(kind="gratitude", title="B", when=now - timedelta(hours=1))
    c = entries.create(kind="reflection", title="C", when=now - timedelta(days=1))
    rows = entries.list_recent(days=30)
    assert [r.id for r in rows] == [b.id, c.id, a.id]


def test_list_recent_filter_by_kind() -> None:
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    r = entries.create(kind="retro", title="retro", when=now)
    entries.create(kind="reflection", title="ref", when=now)
    rows = entries.list_recent(days=30, kind="retro")
    assert {x.id for x in rows} == {r.id}


def test_search_in_title_and_body() -> None:
    from lifeos.spirituality import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="reflection", title="dejar ir", when=now,
                       body="aprender a soltar")
    b = entries.create(kind="gratitude", title="otra cosa", when=now)
    hits = entries.search("soltar")
    assert {r.id for r in hits} == {a.id}


def test_attach_reminder_id_persists() -> None:
    """reminder_id (link to weekly retro reminder) round-trips."""
    from lifeos.spirituality import entries
    e = entries.create(kind="retro", title="x", when=datetime.now(timezone.utc),
                       reminder_id="01ABCREMINDER")
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.reminder_id == "01ABCREMINDER"


def test_soft_delete() -> None:
    from lifeos.spirituality import entries
    e = entries.create(kind="reflection", title="x",
                       when=datetime.now(timezone.utc))
    assert entries.delete(e.id) is True
    assert entries.get(e.id) is None
    assert all(r.id != e.id for r in entries.list_recent(days=30))
