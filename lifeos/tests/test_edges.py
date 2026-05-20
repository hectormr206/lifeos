"""Tests for lifeos.edges DAO."""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_create_edge_roundtrip() -> None:
    from lifeos import edges
    e = edges.create(
        src=("finance", "01ABC"), dst=("health", "01XYZ"),
        rel="caused-by", metadata={"why": "stress from money"},
    )
    assert e.id
    assert e.src_domain == "finance"
    assert e.dst_id == "01XYZ"
    assert e.rel == "caused-by"
    assert e.metadata == {"why": "stress from money"}


def test_neighbors_outbound() -> None:
    from lifeos import edges
    e1 = edges.create(src=("finance", "A"), dst=("health", "X"), rel="caused-by")
    e2 = edges.create(src=("finance", "A"), dst=("health", "Y"), rel="precedes")
    e3 = edges.create(src=("finance", "B"), dst=("health", "X"), rel="caused-by")

    out = edges.neighbors("finance", "A")
    assert {e.id for e in out} == {e1.id, e2.id}


def test_neighbors_filter_by_rel() -> None:
    from lifeos import edges
    e1 = edges.create(src=("finance", "A"), dst=("health", "X"), rel="caused-by")
    e2 = edges.create(src=("finance", "A"), dst=("health", "Y"), rel="precedes")

    out = edges.neighbors("finance", "A", rel="caused-by")
    assert {e.id for e in out} == {e1.id}


def test_inbound() -> None:
    from lifeos import edges
    e1 = edges.create(src=("finance", "A"), dst=("health", "X"), rel="caused-by")
    e2 = edges.create(src=("finance", "B"), dst=("health", "X"), rel="precedes")
    edges.create(src=("finance", "C"), dst=("health", "Y"), rel="caused-by")

    inc = edges.inbound("health", "X")
    assert {e.id for e in inc} == {e1.id, e2.id}


def test_by_relation_with_domain_filter() -> None:
    from lifeos import edges
    e1 = edges.create(src=("finance", "A"), dst=("health", "X"), rel="caused-by")
    e2 = edges.create(src=("health", "Y"), dst=("health", "Z"), rel="caused-by")
    edges.create(src=("finance", "B"), dst=("finance", "C"), rel="precedes")

    out = edges.by_relation("caused-by", src_domain="finance")
    assert {e.id for e in out} == {e1.id}


def test_create_requires_both_endpoints() -> None:
    from lifeos import edges
    with pytest.raises(ValueError):
        edges.create(src=("", "x"), dst=("y", "z"), rel="caused-by")
    with pytest.raises(ValueError):
        edges.create(src=("a", "b"), dst=("c", ""), rel="caused-by")


def test_delete_removes_edge() -> None:
    from lifeos import edges
    e = edges.create(src=("finance", "A"), dst=("health", "X"), rel="caused-by")
    assert edges.delete(e.id) is True
    assert edges.neighbors("finance", "A") == []


def test_link_many_convenience() -> None:
    from lifeos import edges
    es = edges.link_many(
        src=("finance", "purchase1"),
        dsts=[("reminders", "rem1"), ("reminders", "rem2")],
        rel="triggered-by",
    )
    assert len(es) == 2
    assert all(e.src_id == "purchase1" for e in es)
