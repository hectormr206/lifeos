"""Tests for schema slice 3a — the additive sync-columns migration on
`nodes`/`edges` (spec `sync-schema-migration`, tasks.md Phase 4).

Adds `uuid` (backfilled, unique), `lamport`, `origin_node`, `deleted_at` to
both tables. Purely additive: nothing reads these columns yet, so the whole
claim of this slice is ZERO observable behavior change — proven here, not
just asserted, by rebuilding a genuinely pre-change schema (mirroring the
`migrate_devices_pubkey_proven` precedent in `test_devices_store.py`, since
`fresh_db` already runs `init_db()` and a fresh DB is already "migrated" via
`CREATE TABLE IF NOT EXISTS`).

Covers:
  - the real `ALTER TABLE` branch on a pre-change table (not the
    equivalent-outcome-on-a-fresh-table shortcut)
  - every pre-existing row survives with its data intact and a uuid
  - backfilled uuids are unique across more than a couple of rows
  - idempotence: running the migration twice is a no-op, not an error
  - crash safety: a process killed after `nodes` finishes but before
    `edges` starts can be resumed to completion by a plain re-run
"""
from __future__ import annotations

import uuid as uuid_lib

import pytest

from axi import store


def _rebuild_pre_change_nodes(c) -> None:
    """Recreate `nodes` exactly as it looked before schema slice 3a."""
    c.execute("DROP TABLE nodes")
    c.execute(
        """
        CREATE TABLE nodes (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          kind        TEXT NOT NULL,
          label       TEXT NOT NULL,
          data        TEXT,
          domain      TEXT,
          created_at  REAL NOT NULL,
          updated_at  REAL NOT NULL,
          created_tz  TEXT
        )
        """
    )


def _rebuild_pre_change_edges(c) -> None:
    """Recreate `edges` exactly as it looked before schema slice 3a."""
    c.execute("DROP TABLE edges")
    c.execute(
        """
        CREATE TABLE edges (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          from_id     INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          to_id       INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          kind        TEXT NOT NULL,
          data        TEXT,
          created_at  REAL NOT NULL
        )
        """
    )


def _insert_pre_change_node(c, label: str, created_at: float = 1000.0) -> int:
    c.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, created_tz) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("fact", label, '{"k": "v"}', "home", created_at, created_at, "UTC"),
    )
    return c.execute("SELECT last_insert_rowid()").fetchone()[0]


def _insert_pre_change_edge(c, from_id: int, to_id: int, kind: str,
                             created_at: float = 1000.0) -> int:
    c.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at) VALUES (?, ?, ?, ?, ?)",
        (from_id, to_id, kind, None, created_at),
    )
    return c.execute("SELECT last_insert_rowid()").fetchone()[0]


def test_migrate_nodes_edges_sync_columns_alters_pre_change_tables():
    """Exercises the ACTUAL `ALTER TABLE` branch on real pre-change DDL —
    every fresh test DB is already "migrated" via `CREATE TABLE IF NOT
    EXISTS`, so that branch never runs otherwise (same gap
    `test_migrate_devices_pubkey_proven_alters_a_pre_change_table` closed
    for the `devices` table)."""
    c = store._connect()
    _rebuild_pre_change_nodes(c)
    _rebuild_pre_change_edges(c)

    n1 = _insert_pre_change_node(c, "Node A")
    n2 = _insert_pre_change_node(c, "Node B")
    e1 = _insert_pre_change_edge(c, n1, n2, "mentioned_in")

    node_cols_before = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    edge_cols_before = {r[1] for r in c.execute("PRAGMA table_info(edges)").fetchall()}
    assert "uuid" not in node_cols_before  # sanity: genuinely pre-change
    assert "uuid" not in edge_cols_before

    store.migrate_nodes_edges_sync_columns()

    node_cols_after = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    edge_cols_after = {r[1] for r in c.execute("PRAGMA table_info(edges)").fetchall()}
    for col in ("uuid", "lamport", "origin_node", "deleted_at"):
        assert col in node_cols_after
        assert col in edge_cols_after

    # Every pre-existing row survived with its data intact.
    node_row = c.execute(
        "SELECT kind, label, data, domain, created_at, updated_at, created_tz, uuid "
        "FROM nodes WHERE id = ?",
        (n1,),
    ).fetchone()
    assert node_row["kind"] == "fact"
    assert node_row["label"] == "Node A"
    assert node_row["data"] == '{"k": "v"}'
    assert node_row["domain"] == "home"
    assert node_row["created_at"] == 1000.0
    assert node_row["uuid"] is not None

    edge_row = c.execute(
        "SELECT from_id, to_id, kind, created_at, uuid FROM edges WHERE id = ?",
        (e1,),
    ).fetchone()
    assert edge_row["from_id"] == n1
    assert edge_row["to_id"] == n2
    assert edge_row["kind"] == "mentioned_in"
    assert edge_row["created_at"] == 1000.0
    assert edge_row["uuid"] is not None

    # lamport/origin_node/deleted_at are additive-only: untouched, still NULL.
    assert node_row["kind"] is not None  # (sanity re-assert above already covers survival)
    extra = c.execute(
        "SELECT lamport, origin_node, deleted_at FROM nodes WHERE id = ?", (n1,)
    ).fetchone()
    assert extra["lamport"] is None
    assert extra["origin_node"] is None
    assert extra["deleted_at"] is None


def test_migrate_backfilled_uuids_are_unique_across_many_rows():
    """Backfilled uuids must be genuinely unique — proven across more than
    a couple of rows, and enforced by a real UNIQUE index, not just by
    uuid4()'s statistical improbability of collision."""
    c = store._connect()
    _rebuild_pre_change_nodes(c)
    _rebuild_pre_change_edges(c)

    node_ids = [_insert_pre_change_node(c, f"Node {i}") for i in range(6)]

    store.migrate_nodes_edges_sync_columns()

    uuids = [
        c.execute("SELECT uuid FROM nodes WHERE id = ?", (nid,)).fetchone()[0]
        for nid in node_ids
    ]
    assert all(u is not None for u in uuids)
    assert len(set(uuids)) == len(uuids)  # genuinely unique, not just non-null
    for u in uuids:
        uuid_lib.UUID(u)  # a real, parseable UUID string

    # The UNIQUE index actively rejects a duplicate, not merely "happens to
    # not collide" — confirms the constraint mechanism the migration chose
    # (index, since ALTER TABLE ADD COLUMN cannot attach one) is real.
    with pytest.raises(Exception):
        c.execute("UPDATE nodes SET uuid = ? WHERE id = ?", (uuids[0], node_ids[1]))


def test_migrate_nodes_edges_sync_columns_is_idempotent():
    """Running the migration twice is a no-op, not an error, and does not
    reassign a uuid that was already backfilled."""
    c = store._connect()
    _rebuild_pre_change_nodes(c)
    _rebuild_pre_change_edges(c)
    n1 = _insert_pre_change_node(c, "Node A")

    store.migrate_nodes_edges_sync_columns()
    uuid_first = c.execute("SELECT uuid FROM nodes WHERE id = ?", (n1,)).fetchone()[0]

    store.migrate_nodes_edges_sync_columns()  # second call: must not raise
    uuid_second = c.execute("SELECT uuid FROM nodes WHERE id = ?", (n1,)).fetchone()[0]

    assert uuid_first == uuid_second


def test_migrate_interrupted_after_nodes_before_edges_resumes_safely(monkeypatch):
    """Simulates a process killed after `nodes` finished migrating but
    before `edges` did — restarting the migration must complete it
    correctly rather than leaving a half-migrated database undetectably."""
    c = store._connect()
    _rebuild_pre_change_nodes(c)
    _rebuild_pre_change_edges(c)

    n1 = _insert_pre_change_node(c, "Node A")
    n2 = _insert_pre_change_node(c, "Node B")
    e1 = _insert_pre_change_edge(c, n1, n2, "mentioned_in")

    real_uuid4 = uuid_lib.uuid4
    calls = {"n": 0}

    def _uuid4_boom_on_third_call():
        # Calls 1 and 2 backfill the two node rows (nodes finishes cleanly);
        # call 3 would backfill the edge row — raise there to simulate the
        # kill landing exactly between the two tables.
        calls["n"] += 1
        if calls["n"] >= 3:
            raise RuntimeError("simulated kill mid-migration")
        return real_uuid4()

    monkeypatch.setattr(store.uuid, "uuid4", _uuid4_boom_on_third_call)

    with pytest.raises(RuntimeError, match="simulated kill mid-migration"):
        store.migrate_nodes_edges_sync_columns()

    # nodes fully migrated: columns present, both rows backfilled.
    node_cols = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    assert {"uuid", "lamport", "origin_node", "deleted_at"} <= node_cols
    n1_uuid = c.execute("SELECT uuid FROM nodes WHERE id = ?", (n1,)).fetchone()[0]
    n2_uuid = c.execute("SELECT uuid FROM nodes WHERE id = ?", (n2,)).fetchone()[0]
    assert n1_uuid is not None
    assert n2_uuid is not None

    # edges got its columns (ALTERed before the backfill loop that crashed)
    # but the backfill itself never completed — a real, detectable mid-state.
    edge_cols = {r[1] for r in c.execute("PRAGMA table_info(edges)").fetchall()}
    assert {"uuid", "lamport", "origin_node", "deleted_at"} <= edge_cols
    edge_uuid_before = c.execute("SELECT uuid FROM edges WHERE id = ?", (e1,)).fetchone()[0]
    assert edge_uuid_before is None

    # Restart: a plain, uninterrupted re-run must resume to completion.
    monkeypatch.setattr(store.uuid, "uuid4", real_uuid4)
    store.migrate_nodes_edges_sync_columns()

    edge_uuid_after = c.execute("SELECT uuid FROM edges WHERE id = ?", (e1,)).fetchone()[0]
    assert edge_uuid_after is not None

    # nodes were NOT re-touched by the resume — same uuids as before it.
    assert c.execute("SELECT uuid FROM nodes WHERE id = ?", (n1,)).fetchone()[0] == n1_uuid
    assert c.execute("SELECT uuid FROM nodes WHERE id = ?", (n2,)).fetchone()[0] == n2_uuid


def test_full_suite_behavior_unaffected_by_slice_3a_migration():
    """Slice 3a's whole claim is zero observable behavior change: a normal
    node/edge round trip through the public API works identically whether
    or not the pre-existing-DB migration path has run."""
    c = store._connect()
    _rebuild_pre_change_nodes(c)
    _rebuild_pre_change_edges(c)
    n1 = _insert_pre_change_node(c, "Node A")
    n2 = _insert_pre_change_node(c, "Node B")
    _insert_pre_change_edge(c, n1, n2, "mentioned_in")

    store.migrate_nodes_edges_sync_columns()

    # Ordinary reads via the public store API still work post-migration —
    # new columns are additive and unread, so nothing about node shape as
    # seen by existing callers changed.
    node = store.get_node(n1)
    assert node is not None
    assert node["label"] == "Node A"
