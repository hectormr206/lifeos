"""Tests for lifeos.finance.entries DAO + encrypted store."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    from lifeos.finance import store
    store.apply_migrations()
    yield


def test_finance_db_is_encrypted(tmp_path: Path) -> None:
    from lifeos.finance import store, entries
    entries.create(kind="expense", title="café", amount=50, when=datetime.now(timezone.utc))
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "DB header is plaintext — encryption broken"


def test_create_expense_roundtrip() -> None:
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="expense", title="Soriana - compra semanal",
        amount=850.50, currency="MXN",
        category="food", merchant="Soriana",
        when=now, tags=["recurring"], source="manual",
    )
    assert e.id
    fetched = entries.get(e.id)
    assert fetched is not None
    assert fetched.kind == "expense"
    assert fetched.amount == 850.50
    assert fetched.category == "food"
    assert fetched.merchant == "Soriana"
    assert fetched.tags == ["recurring"]


def test_create_rejects_negative_amount() -> None:
    from lifeos.finance import entries
    with pytest.raises(ValueError, match="amount"):
        entries.create(
            kind="expense", title="x", amount=-10,
            when=datetime.now(timezone.utc),
        )


def test_create_rejects_bad_kind() -> None:
    from lifeos.finance import entries
    with pytest.raises(ValueError, match="kind"):
        entries.create(
            kind="totally_wrong", title="x", amount=1,
            when=datetime.now(timezone.utc),
        )


def test_big_purchase_auto_sets_reflect_at() -> None:
    """big_purchase entries get a +7d reflection by default."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="big_purchase", title="auriculares Bose",
        amount=4500, when=now,
    )
    assert e.reflect_at is not None
    delta = (e.reflect_at - now).total_seconds()
    assert 6.5 * 86400 < delta < 7.5 * 86400  # ~7d


def test_big_purchase_explicit_reflect_at_respected() -> None:
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    custom = now + timedelta(days=3)
    e = entries.create(
        kind="big_purchase", title="x", amount=2000,
        when=now, reflect_at=custom,
    )
    assert e.reflect_at is not None
    delta = abs((e.reflect_at - custom).total_seconds())
    assert delta < 5


def test_list_recent_kind_filter() -> None:
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    ex = entries.create(kind="expense", title="café", amount=50, when=now)
    inc = entries.create(kind="income", title="salario", amount=15000, when=now)
    sav = entries.create(kind="savings", title="ahorro", amount=2000, when=now)

    only_ex = entries.list_recent(days=30, kind="expense")
    assert {r.id for r in only_ex} == {ex.id}


def test_pending_reflections_returns_only_due() -> None:
    """Returns big purchases where reflect_at <= now AND reflection_done=0."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    # Due (reflect_at in the past)
    due = entries.create(
        kind="big_purchase", title="comprado hace 8 días", amount=3000,
        when=now - timedelta(days=8), reflect_at=now - timedelta(days=1),
    )
    # Not due yet (reflect_at in the future)
    future = entries.create(
        kind="big_purchase", title="ayer", amount=3000,
        when=now - timedelta(days=1),  # auto-sets reflect_at to +7d from when
    )
    # Already reflected
    done = entries.create(
        kind="big_purchase", title="resuelto", amount=3000,
        when=now - timedelta(days=20), reflect_at=now - timedelta(days=13),
    )
    entries.mark_reflected(done.id, tag="planned")

    pending_ids = {r.id for r in entries.pending_reflections()}
    assert due.id in pending_ids
    assert future.id not in pending_ids
    assert done.id not in pending_ids


def test_mark_reflected_adds_tag_and_sets_flag() -> None:
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    e = entries.create(
        kind="big_purchase", title="iPhone", amount=20000,
        when=now, reflect_at=now,
    )
    entries.mark_reflected(e.id, tag="impulsive")
    after = entries.get(e.id)
    assert after is not None
    assert "impulsive" in after.tags
    assert after.reflection_done is True


def test_mark_reflected_rejects_bad_tag() -> None:
    from lifeos.finance import entries
    e = entries.create(
        kind="big_purchase", title="x", amount=1000,
        when=datetime.now(timezone.utc),
    )
    with pytest.raises(ValueError, match="tag"):
        entries.mark_reflected(e.id, tag="floppy")


def test_balance_summary() -> None:
    """Quick aggregation: total expenses / income / savings within a window."""
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    entries.create(kind="expense", title="x", amount=100, when=now)
    entries.create(kind="expense", title="y", amount=200, when=now)
    entries.create(kind="income", title="salario", amount=10000, when=now)
    entries.create(kind="savings", title="ahorro", amount=2000, when=now)
    entries.create(kind="big_purchase", title="laptop", amount=20000, when=now)

    summary = entries.summary(days=30)
    assert summary["expenses_total"] == 300        # 100 + 200
    assert summary["income_total"] == 10000
    assert summary["savings_total"] == 2000
    assert summary["big_purchases_total"] == 20000


def test_search_finds_by_merchant_or_title() -> None:
    from lifeos.finance import entries
    now = datetime.now(timezone.utc)
    a = entries.create(kind="expense", title="café latte", merchant="Starbucks",
                       amount=85, when=now)
    b = entries.create(kind="expense", title="comida", merchant="VIPS",
                       amount=200, when=now)

    hits = entries.search("starbucks")
    assert {r.id for r in hits} == {a.id}
    hits = entries.search("café")
    assert {r.id for r in hits} == {a.id}


def test_soft_delete() -> None:
    from lifeos.finance import entries
    e = entries.create(kind="expense", title="x", amount=50,
                       when=datetime.now(timezone.utc))
    assert entries.delete(e.id) is True
    assert all(r.id != e.id for r in entries.list_recent(days=30))
