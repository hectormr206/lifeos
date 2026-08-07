"""Backfill: link EXISTING family-subject fact nodes to their person node.

Nodes written before the involves-linking existed carry data.subject but no
graph edge to the person. backfill_subject_person_links repairs them: for each
fact node with data.subject set and no 'involves' edge, it resolves the hub's
typed relation edge (hub --esposa--> Ana) and adds fact --involves--> Ana.

This function is NEVER auto-run against the real DB; it is an explicit,
human-invoked repair (CLI: python -m axi.backfill --subject-links).
"""
from __future__ import annotations

import pytest


@pytest.fixture()
def hub_with_wife(monkeypatch):
    """User hub 'Héctor' + person 'Ana' + typed edge hub --esposa--> Ana."""
    from axi import identity, store
    monkeypatch.setattr(identity, "user_name", lambda: "Héctor")
    hub = store.add_node(kind="person", label="Héctor", data={"role": "user"}, domain=None)
    ana = store.add_node(kind="person", label="Ana", data={"entity": True}, domain=None)
    store.add_edge(hub, ana, "esposa")
    return hub, ana


def _involves(from_id: int) -> list[int]:
    from axi import store
    rows = store._connect().execute(
        "SELECT (SELECT id FROM nodes WHERE uuid = edges.dst_uuid) AS to_id "
        "FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) "
        "AND relation='involves'",
        (from_id,),
    ).fetchall()
    return [r["to_id"] for r in rows]


def test_backfill_links_existing_subject_nodes(hub_with_wife) -> None:
    from axi import identity, store
    _hub, ana = hub_with_wife
    # Two pre-existing family-subject fact nodes with NO involves edge (like 255/256).
    n1 = store.add_node("fact", "presión 121/79, pulso 61",
                        data={"subject": "esposa"}, domain="health")
    n2 = store.add_node("fact", "presión 108/72, pulso 66",
                        data={"subject": "esposa"}, domain="health")
    assert _involves(n1) == [] and _involves(n2) == []

    updated = identity.backfill_subject_person_links()

    assert updated == 2
    assert ana in _involves(n1)
    assert ana in _involves(n2)


def test_backfill_is_idempotent(hub_with_wife) -> None:
    from axi import identity, store
    _hub, ana = hub_with_wife
    n1 = store.add_node("fact", "presión 121/79, pulso 61",
                        data={"subject": "esposa"}, domain="health")
    assert identity.backfill_subject_person_links() == 1
    # Second run creates nothing new (edge already present).
    assert identity.backfill_subject_person_links() == 0
    assert _involves(n1) == [ana]


def test_backfill_dry_run_creates_no_edges(hub_with_wife) -> None:
    from axi import identity, store
    _hub, _ana = hub_with_wife
    n1 = store.add_node("fact", "presión 121/79, pulso 61",
                        data={"subject": "esposa"}, domain="health")
    would = identity.backfill_subject_person_links(dry_run=True)
    assert would == 1           # reports what it WOULD link
    assert _involves(n1) == []  # but writes nothing


def test_backfill_skips_self_nodes(hub_with_wife) -> None:
    """A fact with no subject (the user's own) is never linked as 'involves'."""
    from axi import identity, store
    _hub, _ana = hub_with_wife
    n_self = store.add_node("fact", "presión 118/74", data={}, domain="health")
    assert identity.backfill_subject_person_links() == 0
    assert _involves(n_self) == []
