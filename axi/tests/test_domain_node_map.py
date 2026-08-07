"""Tests for domain_node_map bridge table — Slice 2, tasks 2.1 (RED) / 2.2 (GREEN).

domain_node_map(domain TEXT, entry_id TEXT, node_id INTEGER REFERENCES nodes(id),
                PRIMARY KEY(domain, entry_id))

Scenarios tested:
- Table is created with the correct schema after init_db.
- upsert_domain_node_map inserts a mapping and returns the node_id.
- A duplicate (domain, entry_id) pair is idempotent — returns the existing node_id.
- get_node_for_domain_entry returns node_id or None.
"""
from __future__ import annotations

import time

import pytest
import uuid as _uuid


def _insert_fact_node(conn, label: str = "test fact", domain: str = "relationships") -> int:
    """Helper: insert a bare fact node and return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", label, "{}", domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


def test_domain_node_map_table_exists_after_init_db(monkeypatch):
    """Task 2.1 RED: domain_node_map table exists after init_db."""
    import axi.store as store

    conn = store._connect()
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='domain_node_map'"
    ).fetchone()
    assert row is not None, "domain_node_map table must exist after init_db()"


def test_domain_node_map_schema(monkeypatch):
    """Task 2.1 RED: domain_node_map has the expected columns."""
    import axi.store as store

    conn = store._connect()
    cols = {r[1] for r in conn.execute("PRAGMA table_info(domain_node_map)").fetchall()}
    assert "domain" in cols, "missing column: domain"
    assert "entry_id" in cols, "missing column: entry_id"
    assert "node_id" in cols, "missing column: node_id"
    assert "created_at" in cols, "missing column: created_at"


def test_upsert_domain_node_map_inserts_and_returns_node_id(monkeypatch):
    """Task 2.1 RED: upsert_domain_node_map inserts a mapping and returns node_id."""
    import axi.store as store
    from axi.store import upsert_domain_node_map, get_node_for_domain_entry

    conn = store._connect()
    node_id = _insert_fact_node(conn, "hello world", "relationships")

    result = upsert_domain_node_map("relationships", "entry-001", node_id)
    assert result == node_id

    looked_up = get_node_for_domain_entry("relationships", "entry-001")
    assert looked_up == node_id


def test_upsert_domain_node_map_idempotent(monkeypatch):
    """Task 2.1 RED: duplicate (domain, entry_id) insert returns existing node_id, no duplicate row."""
    import axi.store as store
    from axi.store import upsert_domain_node_map, get_node_for_domain_entry

    conn = store._connect()
    node_id = _insert_fact_node(conn, "idempotent test", "relationships")

    r1 = upsert_domain_node_map("relationships", "entry-dupe", node_id)
    r2 = upsert_domain_node_map("relationships", "entry-dupe", node_id)
    assert r1 == node_id
    assert r2 == node_id

    # Only one row exists.
    count = conn.execute(
        "SELECT COUNT(*) FROM domain_node_map WHERE domain='relationships' AND entry_id='entry-dupe'"
    ).fetchone()[0]
    assert count == 1, "duplicate row found — upsert is not idempotent"


def test_get_node_for_domain_entry_returns_none_when_missing(monkeypatch):
    """Task 2.1 RED: get_node_for_domain_entry returns None when entry not mapped."""
    from axi.store import get_node_for_domain_entry

    result = get_node_for_domain_entry("relationships", "nonexistent-entry")
    assert result is None
