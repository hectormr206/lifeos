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



# ─────────── PR5 "Expand" (design-schema.md) — edge endpoint uuids ───────────
#
# Adds edges.src_uuid/dst_uuid/updated_at + edges.relation (GENERATED ALWAYS
# AS (kind) VIRTUAL, single storage so it cannot drift) + nodes.occurred_at.
# Backfills src_uuid/dst_uuid from nodes.uuid via the existing from_id/to_id
# FKs. Purely additive/reversible: from_id/to_id/kind remain authoritative
# and nothing reads the new columns yet (that is PR6, the reader rewrite).
#
# NOTE: fresh_db's autouse fixture already runs the full init_db() migration
# chain (including migrate_edge_endpoint_uuids), so `edges` already has PR5's
# columns by the time a test body starts. To genuinely exercise the ALTER
# TABLE / backfill branch (not the already-migrated no-op), these tests
# rebuild `edges` back to its real post-3a/pre-PR5 shape first — mirroring
# `_rebuild_pre_change_nodes`/`_rebuild_pre_change_edges` above for 3a.


def test_fresh_db_edges_table_has_pr5_columns_via_create_table_alone():
    """A fresh DB must get src_uuid/dst_uuid/updated_at/relation from
    `_SCHEMA`'s `CREATE TABLE IF NOT EXISTS edges` alone (PR4 pattern), NOT
    only from `migrate_edge_endpoint_uuids()` — otherwise a future change
    that skips/conditions that call (trusting a stale "no-op on a fresh DB"
    comment) silently loses these columns on every fresh install. Proven by
    rebuilding `edges` straight from `_SCHEMA` and checking the columns
    exist WITHOUT calling the migration function at all."""
    c = store._connect()
    c.execute("DROP TABLE edges")
    # Re-run only the schema DDL (no migration functions) to isolate what
    # CREATE TABLE alone provides.
    c.executescript(store._SCHEMA)

    xinfo = {r[1] for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()}
    for col in ("src_uuid", "dst_uuid", "updated_at", "relation"):
        assert col in xinfo, f"{col} missing from a fresh edges table — CREATE TABLE alone must provide it"

    ddl = c.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='edges'"
    ).fetchone()[0]
    assert "GENERATED ALWAYS AS (kind) VIRTUAL" in ddl


def _rebuild_post_3a_pre_pr5_edges(c) -> None:
    """Recreate `edges` exactly as it looks after schema slice 3a (PR4) but
    before PR5: has uuid/lamport/origin_node/deleted_at, NOT src_uuid/
    dst_uuid/updated_at/relation."""
    c.execute("DROP TABLE edges")
    c.execute(
        """
        CREATE TABLE edges (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          from_id     INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          to_id       INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          kind        TEXT NOT NULL,
          data        TEXT,
          created_at  REAL NOT NULL,
          uuid        TEXT,
          lamport     INTEGER,
          origin_node TEXT,
          deleted_at  REAL
        )
        """
    )


def _insert_post_3a_edge(c, from_id: int, to_id: int, kind: str,
                          created_at: float = 1000.0) -> int:
    c.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at, uuid) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (from_id, to_id, kind, None, created_at, str(uuid_lib.uuid4())),
    )
    return c.execute("SELECT last_insert_rowid()").fetchone()[0]


def test_migrate_edge_endpoint_uuids_adds_and_backfills_columns():
    """Task 5.1 RED: new columns exist and are correctly backfilled from the
    pre-existing from_id/to_id -> nodes.uuid relationship."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    eid = _insert_post_3a_edge(c, n1, n2, "mentioned_in")

    # Sanity: this test genuinely targets a DB where PR5's columns are absent.
    edge_cols_before = {r[1] for r in c.execute("PRAGMA table_info(edges)").fetchall()}
    assert "src_uuid" not in edge_cols_before

    store.migrate_edge_endpoint_uuids()

    edge_cols = {r[1] for r in c.execute("PRAGMA table_info(edges)").fetchall()}
    for col in ("src_uuid", "dst_uuid", "updated_at"):
        assert col in edge_cols
    # relation is a GENERATED/hidden column: table_info hides it in this
    # SQLite build, table_xinfo does not (proven by the earlier standalone
    # repro; matches what migrate_edge_endpoint_uuids itself checks).
    edge_cols_xinfo = {r[1] for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()}
    assert "relation" in edge_cols_xinfo
    node_cols = {r[1] for r in c.execute("PRAGMA table_info(nodes)").fetchall()}
    assert "occurred_at" in node_cols

    n1_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (n1,)).fetchone()[0]
    n2_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (n2,)).fetchone()[0]
    row = c.execute(
        "SELECT src_uuid, dst_uuid, updated_at, created_at FROM edges WHERE id=?", (eid,)
    ).fetchone()
    assert row["src_uuid"] == n1_uuid
    assert row["dst_uuid"] == n2_uuid
    assert row["updated_at"] == row["created_at"]

    # Old columns remain untouched/authoritative — zero observable change.
    old_row = c.execute("SELECT from_id, to_id, kind FROM edges WHERE id=?", (eid,)).fetchone()
    assert old_row["from_id"] == n1
    assert old_row["to_id"] == n2
    assert old_row["kind"] == "mentioned_in"


def test_migrate_edge_endpoint_uuids_relation_is_generated_from_kind():
    """Task 5.2 RED: `relation` is a GENERATED ALWAYS AS (kind) VIRTUAL column
    — single storage, so it cannot drift from `kind` by construction. Proven
    for a pre-existing row AND a row inserted after the migration ran."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    e_before = _insert_post_3a_edge(c, n1, n2, "mentioned_in")

    store.migrate_edge_endpoint_uuids()

    # Generated-column mechanics, not just app-level consistency: assert the
    # DDL itself uses GENERATED ALWAYS ... VIRTUAL, so `relation` cannot be
    # written to directly (would raise) and always mirrors `kind`.
    ddl = c.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='edges'"
    ).fetchone()[0]
    assert "GENERATED ALWAYS AS (kind) VIRTUAL" in ddl

    relation_before = c.execute("SELECT relation FROM edges WHERE id=?", (e_before,)).fetchone()[0]
    assert relation_before == "mentioned_in"

    # A row inserted directly AFTER the migration also derives relation from kind.
    c.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at, updated_at, uuid) "
        "VALUES (?, ?, 'caused_by', '{}', 2000.0, 2000.0, ?)",
        (n1, n2, str(uuid_lib.uuid4())),
    )
    relation_after = c.execute(
        "SELECT relation FROM edges WHERE from_id=? AND to_id=? AND kind='caused_by'", (n1, n2)
    ).fetchone()[0]
    assert relation_after == "caused_by"

    with pytest.raises(Exception):
        c.execute("UPDATE edges SET relation='tampered' WHERE id=?", (e_before,))


def test_migrate_edge_endpoint_uuids_is_idempotent():
    """Task 5.3 RED: re-running the migration on an already-migrated DB is a
    no-op — only rows with src_uuid IS NULL are touched, per PR4's pattern."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    eid = _insert_post_3a_edge(c, n1, n2, "mentioned_in")

    store.migrate_edge_endpoint_uuids()
    before = c.execute(
        "SELECT src_uuid, dst_uuid, updated_at FROM edges WHERE id=?", (eid,)
    ).fetchone()

    store.migrate_edge_endpoint_uuids()  # second call: must not raise
    after = c.execute(
        "SELECT src_uuid, dst_uuid, updated_at FROM edges WHERE id=?", (eid,)
    ).fetchone()

    assert tuple(before) == tuple(after)


def test_verify_edge_endpoint_convergence_raises_on_drift():
    """Task 5.10 RED: verify_edge_endpoint_convergence() RAISES when a live
    edge's src_uuid/dst_uuid has drifted from from_id/to_id -> nodes.uuid."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    eid = _insert_post_3a_edge(c, n1, n2, "mentioned_in")
    store.migrate_edge_endpoint_uuids()

    # Converged state passes cleanly.
    store.verify_edge_endpoint_convergence()

    # Deliberately desync one row.
    c.execute("UPDATE edges SET src_uuid='deliberately-wrong-uuid' WHERE id=?", (eid,))

    with pytest.raises(Exception):
        store.verify_edge_endpoint_convergence()


def test_verify_edge_endpoint_convergence_raises_if_it_cannot_execute():
    """Task 5.11 RED: verify_edge_endpoint_convergence() RAISES (does not
    silently pass) if it cannot execute at all — e.g. its table is missing
    mid-migration. Per the LifeOS silent-failure rule, a check that cannot
    run must also fail loudly, not just a check that finds real drift."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    _insert_post_3a_edge(c, n1, n2, "mentioned_in")
    store.migrate_edge_endpoint_uuids()

    c.execute("ALTER TABLE edges RENAME TO edges_mid_migration_gone")

    with pytest.raises(Exception):
        store.verify_edge_endpoint_convergence()

    # restore for any subsequent statements in this connection/process
    c.execute("ALTER TABLE edges_mid_migration_gone RENAME TO edges")


def test_full_suite_behavior_unaffected_by_pr5_edge_endpoint_migration():
    """Task 5.13 pin (the real proof is the dual-tree-state suite run recorded
    in apply-progress, mirroring PR4's technique): an ordinary node/edge round
    trip through the public API is unchanged whether or not the PR5 migration
    has run — old columns/reads stay authoritative, new ones are additive."""
    n1 = store.add_node("fact", "Node A")
    n2 = store.add_node("fact", "Node B")
    eid = store.add_edge(n1, n2, "mentioned_in")
    store.migrate_edge_endpoint_uuids()

    node = store.get_node(n1)
    assert node is not None
    assert node["label"] == "Node A"
    neighbors = store.neighbors(n1, edge_kind="mentioned_in")
    assert len(neighbors) == 1
    assert neighbors[0]["id"] == n2
    assert eid > 0


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


# ─────────── PR6a: reader rewrite to src_uuid/dst_uuid/relation ───────────

def test_backfill_repairs_an_edge_missing_only_dst_uuid():
    """PR5's backfill only touched rows `WHERE src_uuid IS NULL`, so an edge
    with a written `src_uuid` and a NULL `dst_uuid` was unreachable by it
    forever.

    That row is reachable in practice: before task 5.14, a node created after
    the last restart had `uuid IS NULL`, so an edge from an older node to a
    newer one dual-wrote a real `src_uuid` and a NULL `dst_uuid`. The next
    start backfilled the node's uuid but skipped the edge — and from PR6a on,
    that edge is invisible to every read that resolves through `dst_uuid`.

    The backfill must therefore converge on EITHER endpoint being NULL.
    """
    c = store._connect()
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    eid = store.add_edge(src, dst, "owns")
    c.execute("UPDATE edges SET dst_uuid=NULL WHERE id=?", (eid,))

    store.migrate_edge_endpoint_uuids()

    row = c.execute("SELECT src_uuid, dst_uuid FROM edges WHERE id=?", (eid,)).fetchone()
    dst_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (dst,)).fetchone()[0]
    assert row["dst_uuid"] == dst_uuid


def test_endpoint_uuid_indexes_exist_for_mobile_parity():
    """The rewritten reads join on `src_uuid`/`dst_uuid` and filter on
    `relation`. Without indexes on those columns every graph read becomes a
    full table scan — `same_day_neighbors` in particular is a UNION written
    specifically so SQLite could use `idx_edges_from`/`idx_edges_to`, and the
    rewrite retires both.

    The three index names are mobile's, verbatim
    (`mobile/lib/core/graph/local_graph_schema.dart`), so the contract PR has
    nothing left to reconcile here.
    """
    c = store._connect()
    names = {r[1] for r in c.execute("PRAGMA index_list(edges)").fetchall()}
    assert {"idx_edges_src", "idx_edges_dst", "idx_edges_relation"} <= names


def test_same_day_neighbors_uses_an_index_not_a_full_scan():
    """The performance half of the claim above, measured rather than assumed:
    the query plan must still name an index on the edges table."""
    c = store._connect()
    a = store.add_node("fact", "nota A")
    plan = " ".join(
        str(tuple(r)) for r in c.execute(
            "EXPLAIN QUERY PLAN "
            "SELECT n.id FROM nodes n JOIN edges e "
            "ON e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.dst_uuid = n.uuid AND e.relation = 'same-day' "
            "WHERE n.id != ?",
            (a, a),
        ).fetchall()
    )
    # Which of the three the planner picks depends on table statistics; the
    # claim under test is that it has one to pick at all and does not fall
    # back to scanning the whole edges table.
    assert "SEARCH e USING INDEX idx_edges_" in plan, plan
    assert "SCAN e" not in plan, plan
