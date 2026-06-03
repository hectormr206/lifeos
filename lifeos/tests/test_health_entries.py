"""Tests for lifeos.health.entries DAO + sqlcipher store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos.health import store
    store.apply_migrations()
    yield


def test_key_file_generated_with_600_perms() -> None:
    import os
    from lifeos.health.store import _ensure_key, key_path
    _ensure_key()
    p = key_path()
    assert p.exists()
    mode = os.stat(p).st_mode & 0o777
    assert mode == 0o600, f"key file mode {oct(mode)} should be 0o600"


def test_key_file_persisted_between_connections() -> None:
    from lifeos.health.store import _ensure_key
    k1 = _ensure_key()
    k2 = _ensure_key()
    assert k1 == k2
    assert len(k1) == 64  # 32 bytes hex-encoded


def test_db_file_is_actually_encrypted(tmp_path: Path) -> None:
    """Sanity check that an encrypted SQLite DB looks like opaque bytes,
    not a normal SQLite header ('SQLite format 3\\x00')."""
    from lifeos.health import store, entries
    entries.create(kind="note", title="x", when=datetime.now(timezone.utc))
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_symptom_roundtrip() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="symptom",
        title="dolor de garganta",
        when=now,
        body="Empezó esta mañana, intensidad 6/10",
        data={"severity": 6, "location": "garganta"},
        tags=["viral", "estacional"],
        source="chat",
        confidence=0.85,
    )
    assert e.id
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "symptom"
    assert fetched.title == "dolor de garganta"
    assert fetched.data == {"severity": 6, "location": "garganta"}
    assert fetched.tags == ["viral", "estacional"]
    assert fetched.source == "chat"
    assert fetched.confidence == 0.85


def test_create_rejects_bad_kind() -> None:
    from lifeos.health import entries
    with pytest.raises(ValueError, match="kind"):
        entries.create(kind="banana", title="x", when=datetime.now(timezone.utc))


def test_when_must_be_tz_aware() -> None:
    from lifeos.health import entries
    naive = datetime(2026, 6, 1, 9, 0, 0)
    with pytest.raises(ValueError, match="tz-aware"):
        entries.create(kind="note", title="x", when=naive)


def test_list_recent_sorted_desc_by_ts() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e_old = entries.create(kind="note", title="A", when=now - timedelta(days=2))
    e_new = entries.create(kind="note", title="B", when=now - timedelta(hours=1))
    e_mid = entries.create(kind="note", title="C", when=now - timedelta(days=1))

    rows = entries.list_recent(days=30)
    assert [r.id for r in rows] == [e_new.id, e_mid.id, e_old.id]


def test_list_recent_filters_by_kind() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    s = entries.create(kind="symptom", title="dolor", when=now)
    m = entries.create(kind="medication", title="amox", when=now)
    n = entries.create(kind="note", title="reflexión", when=now)

    sym = entries.list_recent(days=30, kind="symptom")
    assert {r.id for r in sym} == {s.id}


def test_search_finds_in_title_and_body() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="symptom", title="dolor de garganta", when=now)
    b = entries.create(kind="note", title="bien", when=now, body="me siento sano")
    c = entries.create(kind="note", title="cansado", when=now)

    hits = entries.search("garganta")
    assert {r.id for r in hits} == {a.id}

    hits = entries.search("sano")
    assert {r.id for r in hits} == {b.id}


def test_soft_delete() -> None:
    from lifeos.health import entries
    e = entries.create(kind="note", title="x", when=datetime.now(timezone.utc))
    assert entries.delete(e.id) is True
    # Deleted entries do not appear in list_recent
    assert all(r.id != e.id for r in entries.list_recent(days=30))
    # But get() still returns them so we can show "(eliminado)" if needed
    assert entries.get(e.id) is None  # default: hide deleted
    assert entries.get(e.id, include_deleted=True) is not None


# ── update() tests ────────────────────────────────────────────────────────────


def test_update_changes_fields() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="note", title="original", when=now,
        body="old body", tags=["a"], source="manual",
    )
    new_when = now + timedelta(hours=1)
    updated = entries.update(
        e.id,
        kind="symptom",
        title="updated",
        when=new_when,
        body="new body",
        tags=["b", "c"],
        data={"severity": 5},
    )
    assert updated is not None
    assert updated.id == e.id
    assert updated.kind == "symptom"
    assert updated.title == "updated"
    assert updated.body == "new body"
    assert updated.tags == ["b", "c"]
    assert updated.data == {"severity": 5}
    # ts reflects new_when
    assert abs((updated.ts - new_when).total_seconds()) < 2
    # source is immutable provenance — unchanged by update()
    assert updated.source == "manual"


def test_update_roundtrips_via_get() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="note", title="x", when=now)
    entries.update(e.id, title="y", kind="note", when=now)
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.title == "y"


def test_update_returns_none_for_missing_id() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    result = entries.update("nonexistent-id", title="x", kind="note", when=now)
    assert result is None


def test_update_returns_none_for_deleted_entry() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="note", title="x", when=now)
    entries.delete(e.id)
    result = entries.update(e.id, title="y", kind="note", when=now)
    assert result is None


def test_update_rejects_invalid_kind() -> None:
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(kind="note", title="x", when=now)
    with pytest.raises(ValueError, match="kind"):
        entries.update(e.id, title="x", kind="banana", when=now)  # type: ignore[arg-type]


def test_update_rejects_naive_datetime() -> None:
    from lifeos.health import entries
    naive = datetime(2026, 6, 1, 9, 0, 0)
    e = entries.create(kind="note", title="x", when=datetime.now(timezone.utc))
    with pytest.raises(ValueError, match="tz-aware"):
        entries.update(e.id, title="x", kind="note", when=naive)


def test_update_clears_optional_fields_when_none() -> None:
    """Passing body=None clears body; tags=None clears tags; data=None clears data."""
    from lifeos.health import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="note", title="x", when=now,
        body="has body", tags=["tag1"], data={"key": "val"},
    )
    updated = entries.update(e.id, title="x", kind="note", when=now,
                             body=None, tags=None, data=None)
    assert updated is not None
    assert updated.body is None
    assert updated.tags == []
    assert updated.data == {}
