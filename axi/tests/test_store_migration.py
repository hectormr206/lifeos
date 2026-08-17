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
    # PR5 asserted `relation` here as `GENERATED ALWAYS AS (kind) VIRTUAL`:
    # one storage cell shared with `kind`, which is what made drift between the
    # two impossible during the expand window. PR8 ENDS that window — `kind` is
    # gone, `relation` is the only name left and carries real storage. The
    # anti-drift property survives for the same reason it was chosen: there is
    # exactly one column, not two kept in step.
    assert "GENERATED ALWAYS" not in ddl
    assert "relation" in ddl
    assert "from_id" not in ddl and "to_id" not in ddl


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

    PR8 note: this half-backfilled state is only REACHABLE on a database that
    has not been rebuilt yet — `dst_uuid NOT NULL` makes it impossible
    afterwards. The test therefore runs against the pre-PR8 shape, which is
    where the repair actually has to work: the owner's real database on the
    morning it is migrated.
    """
    c = store._connect()
    _rebuild_post_3a_pre_pr5_edges(c)
    src = store.add_node("person", "Héctor")
    dst = store.add_node("fact", "usa CachyOS")
    eid = _insert_post_3a_edge(c, src, dst, "owns")
    store.migrate_edge_endpoint_uuids()
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
            "AND e.dst_uuid = n.uuid AND e.relation= 'same-day' "
            "WHERE n.id != ?",
            (a, a),
        ).fetchall()
    )
    # Which of the three the planner picks depends on table statistics; the
    # claim under test is that it has one to pick at all and does not fall
    # back to scanning the whole edges table.
    assert "SEARCH e USING INDEX idx_edges_" in plan, plan
    assert "SCAN e" not in plan, plan


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — task 7.10: the tombstone indexes, in `_SCHEMA` AND in the migration.
#
# Index parity is this chain's most valuable recurring find: PR6a's rewrite
# silently turned every graph read into a full table scan and no test failed.
# PR7 adds `deleted_at IS NULL` to many WHERE clauses, which is another chance
# to change a plan without changing an answer, so both halves are measured.
#
# All plans below are measured WITHOUT running `ANALYZE`, because `store.py`
# never runs it. With statistics on a tiny table the planner abandons the
# MULTI-INDEX OR for old and new alike, which would make the comparison read
# clean while proving nothing.
# ═══════════════════════════════════════════════════════════════════════════


def _plan(c, sql, params=()):
    return "\n".join(str(tuple(r)) for r in c.execute("EXPLAIN QUERY PLAN " + sql, params))


def test_deleted_at_indexes_exist_on_a_fresh_db():
    """Mobile parity: `idx_nodes_deleted` / `idx_edges_deleted`, verbatim."""
    c = store._connect()
    node_idx = {r[1] for r in c.execute("PRAGMA index_list(nodes)").fetchall()}
    edge_idx = {r[1] for r in c.execute("PRAGMA index_list(edges)").fetchall()}
    assert "idx_nodes_deleted" in node_idx, node_idx
    assert "idx_edges_deleted" in edge_idx, edge_idx


def test_deleted_at_indexes_are_partial_on_purpose():
    """They index the TOMBSTONES, not the live rows — measured, not stylistic.

    A full index on `deleted_at` gets chosen for the `deleted_at IS NULL`
    filter that every read now carries, and since nearly every row IS NULL that
    "SEARCH" walks the whole table. Measured with EXPLAIN QUERY PLAN it cost
    the graph-browser and recall queries their MULTI-INDEX OR over
    idx_edges_src/idx_edges_dst: a full scan wearing an index's name, with no
    test failing and no error — the exact defect shape PR6a found once already.

    Restricted to `deleted_at IS NOT NULL` the planner cannot use it for the
    live-row filter at all, and it stays small and genuinely selective for the
    query that does want it: "which rows are tombstoned" (the sync push).

    Asserted on the stored DDL because dropping the `WHERE` clause is a
    one-word edit that nothing else in the suite would notice.
    """
    c = store._connect()
    for name in ("idx_nodes_deleted", "idx_edges_deleted"):
        sql = c.execute(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name=?", (name,)
        ).fetchone()[0]
        assert "WHERE deleted_at IS NOT NULL" in sql, f"{name} is not partial: {sql}"


def test_the_deleted_indexes_are_never_chosen_for_the_live_row_filter():
    """The measurement behind the test above, on the queries PR7 touches.

    This is the one that would catch a well-meaning future edit that made the
    indexes full again "for symmetry with mobile".
    """
    c = store._connect()
    a = store.add_node("fact", "nota A")
    b = store.add_node("fact", "nota B")
    store.add_edge(a, b, "same-day")
    a_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (a,)).fetchone()[0]

    for label, sql, params in (
        ("dashboard node detail / neighborhood",
         "SELECT e.id FROM edges e WHERE (e.src_uuid = ? OR e.dst_uuid = ?) "
         "AND e.deleted_at IS NULL", (a_uuid, a_uuid)),
        ("recall graph relation lines",
         "SELECT e.id FROM edges e "
         "WHERE (e.src_uuid IN (SELECT uuid FROM nodes WHERE id IN (?)) "
         "OR e.dst_uuid IN (SELECT uuid FROM nodes WHERE id IN (?))) "
         "AND e.deleted_at IS NULL", (a, a)),
    ):
        plan = _plan(c, sql, params)
        assert "idx_edges_deleted" not in plan, f"{label}: {plan}"
        assert "MULTI-INDEX OR" in plan, f"{label} lost its OR-index plan: {plan}"
        assert "idx_edges_src" in plan and "idx_edges_dst" in plan, f"{label}: {plan}"


def test_deleted_at_indexes_are_created_by_the_migration_too():
    """A pre-existing database never runs `_SCHEMA`'s CREATE TABLE body.

    PR6a shipped its three indexes in BOTH places for exactly this reason; the
    same rule applies here, and skipping it would leave every already-migrated
    database — i.e. the owner's real one — without them.
    """
    c = store._connect()
    c.execute("DROP INDEX IF EXISTS idx_nodes_deleted")
    c.execute("DROP INDEX IF EXISTS idx_edges_deleted")
    assert "idx_nodes_deleted" not in {
        r[1] for r in c.execute("PRAGMA index_list(nodes)").fetchall()
    }

    store.migrate_edge_endpoint_uuids()

    assert "idx_nodes_deleted" in {
        r[1] for r in c.execute("PRAGMA index_list(nodes)").fetchall()
    }
    assert "idx_edges_deleted" in {
        r[1] for r in c.execute("PRAGMA index_list(edges)").fetchall()
    }


def test_adding_the_deleted_filter_does_not_turn_a_search_into_a_scan():
    """The four shapes PR7 touches, each measured before and after the filter.

    A SEARCH that became a SCAN is invisible to every correctness test in this
    PR: the answers stay identical and the graph just gets slower forever.
    """
    c = store._connect()
    a = store.add_node("fact", "nota A")
    b = store.add_node("fact", "nota B")
    store.add_edge(a, b, "same-day")
    a_uuid = c.execute("SELECT uuid FROM nodes WHERE id=?", (a,)).fetchone()[0]

    shapes = {
        # same_day_neighbors, src arm
        "same_day_src": (
            "SELECT n.id FROM nodes n JOIN edges e "
            "ON e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.dst_uuid = n.uuid AND e.relation= 'same-day' WHERE n.id != ?",
            "SELECT n.id FROM nodes n JOIN edges e "
            "ON e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.dst_uuid = n.uuid AND e.relation= 'same-day' "
            "WHERE n.id != ? AND e.deleted_at IS NULL AND n.deleted_at IS NULL",
            (a, a),
        ),
        # neighbors()
        "neighbors": (
            "SELECT n.* FROM nodes n JOIN edges e ON e.dst_uuid = n.uuid "
            "WHERE e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?)",
            "SELECT n.* FROM nodes n JOIN edges e ON e.dst_uuid = n.uuid "
            "WHERE e.src_uuid = (SELECT uuid FROM nodes WHERE id = ?) "
            "AND e.deleted_at IS NULL AND n.deleted_at IS NULL",
            (a,),
        ),
        # _edge_exists (store/linkers/identity share this shape)
        "edge_exists": (
            "SELECT 1 FROM edges WHERE "
            "src_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
            "dst_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND relation= ? LIMIT 1",
            "SELECT 1 FROM edges WHERE "
            "src_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND "
            "dst_uuid = (SELECT uuid FROM nodes WHERE id = ?) AND relation= ? "
            "AND deleted_at IS NULL LIMIT 1",
            (a, b, "same-day"),
        ),
        # dashboard node detail / neighborhood: the MULTI-INDEX OR shape
        "or_endpoints": (
            "SELECT e.id FROM edges e WHERE e.src_uuid = ? OR e.dst_uuid = ?",
            "SELECT e.id FROM edges e WHERE (e.src_uuid = ? OR e.dst_uuid = ?) "
            "AND e.deleted_at IS NULL",
            (a_uuid, a_uuid),
        ),
    }

    for name, (before_sql, after_sql, params) in shapes.items():
        before = _plan(c, before_sql, params)
        after = _plan(c, after_sql, params)
        assert "SEARCH e" in before, f"{name}: baseline was not a SEARCH — {before}"
        assert "SEARCH e" in after, (
            f"{name}: adding `deleted_at IS NULL` turned a SEARCH into a SCAN\n"
            f"before:\n{before}\nafter:\n{after}"
        )
        assert "SCAN e" not in after, f"{name}: {after}"
        # A SEARCH is not automatically a win. `idx_edges_deleted` on a column
        # that is NULL for nearly every row makes a full table walk LOOK like
        # an indexed seek, which is why "SEARCH, not SCAN" alone is too weak an
        # assertion for this particular change.
        assert "idx_edges_deleted" not in after, (
            f"{name}: the planner fell back to the tombstone index, which "
            f"visits nearly every row\nafter:\n{after}"
        )


def test_pr7_reverts_as_code_but_resurrects_soft_deleted_rows():
    """7.15: the semantic one-wayness of this PR, stated where it is testable.

    The diff reverts cleanly — `deleted_at` is a PR4 column, the delete paths
    go back to `DELETE`, the filters come off. What does NOT revert is the
    data: every row tombstoned while PR7 was live is still sitting in `nodes`
    and `edges`, and the moment the filters are gone it is visible again. The
    user sees memories they deleted come back.

    Asserted rather than written in a comment: the tombstoned row is readable
    by a query with no filter, which is exactly what a reverted reader is.
    """
    nid = store.add_node("fact", "algo que el usuario borró")
    store.delete_node(nid)

    c = store._connect()
    assert c.execute(
        "SELECT deleted_at FROM nodes WHERE id=?", (nid,)
    ).fetchone()["deleted_at"] is not None
    unfiltered = c.execute(
        "SELECT id, label FROM nodes WHERE kind='fact'"
    ).fetchall()
    assert nid in {r["id"] for r in unfiltered}, (
        "a reader without the tombstone filter — i.e. a reverted PR7 — would "
        "not see this row, which would make the revert safe; it is not"
    )
    assert store.get_node(nid) is None, "the filtered reader must still hide it"


# ══════════════════ PR8 — THE POINT OF NO RETURN (tasks 8.7-8.14) ═══════════
#
# Single-transaction rebuild of `nodes`/`edges` to mobile's DDL. After this
# migration runs there is no code-level revert: `from_id`/`to_id`/`kind` are
# gone, so reverting the code gives you queries against columns that no longer
# exist. Recovery is restore-from-verified-backup and nothing else, which is
# why the gate in `test_migration_backup.py` had to be green first.


def _ok_backup() -> str:
    """A backup callable that succeeds. The gate itself is proven in
    `test_migration_backup.py`; these tests are about the rebuild."""
    return "/tmp/pr8-fake-verified-snapshot.db"


def _cols(table: str) -> set[str]:
    # table_xinfo, not table_info: table_info hides GENERATED columns in this
    # SQLite build, so `relation` would read as absent on the OLD table.
    return {
        r[1] for r in store._connect().execute(f"PRAGMA table_xinfo({table})").fetchall()
    }


def _index_names(table: str) -> set[str]:
    return {
        r[0] for r in store._connect().execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
            (table,),
        ).fetchall()
    }


def test_rebuild_drops_the_rowid_endpoints_and_keeps_every_row(pre_pr8_graph):
    """8.7 — the rebuild itself: old columns gone, mobile's shape in place,
    every row still there with its id unchanged."""
    ids = pre_pr8_graph["nodes"]
    uuids = pre_pr8_graph["uuids"]
    c = store._connect()
    assert "from_id" in _cols("edges")  # sanity: genuinely pre-rebuild
    nodes_before = c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    edges_before = c.execute("SELECT COUNT(*) FROM edges").fetchone()[0]

    assert store.migrate_rebuild_graph_tables(backup=_ok_backup) is True

    edge_cols = _cols("edges")
    assert {"from_id", "to_id", "kind"}.isdisjoint(edge_cols)
    assert {"src_uuid", "dst_uuid", "relation", "updated_at"} <= edge_cols
    assert c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0] == nodes_before
    assert c.execute("SELECT COUNT(*) FROM edges").fetchone()[0] == edges_before

    # ids copied EXPLICITLY, never reassigned by AUTOINCREMENT.
    row = c.execute("SELECT uuid, label FROM nodes WHERE id=?", (ids["ana"],)).fetchone()
    assert row["uuid"] == uuids["ana"]
    assert row["label"] == "Ana Ríos"
    # `relation` is now real storage carrying what `kind` held.
    rels = {r[0] for r in c.execute("SELECT relation FROM edges").fetchall()}
    assert {"esposa", "about", "same-day"} <= rels
    # Tombstones are rows too. Dropping them would delete the user's deletions.
    assert c.execute(
        "SELECT deleted_at FROM nodes WHERE id=?", (ids["gone"],)
    ).fetchone()["deleted_at"] is not None


def test_rebuild_sets_user_version_and_is_a_no_op_on_the_second_call(pre_pr8_graph):
    """8.7/8.14 — `PRAGMA user_version` is the idempotence gate. A second call
    must not re-run (and must not take a second backup)."""
    c = store._connect()
    assert c.execute("PRAGMA user_version").fetchone()[0] == 0
    assert store.migrate_rebuild_graph_tables(backup=_ok_backup) is True
    assert c.execute("PRAGMA user_version").fetchone()[0] == \
        store.GRAPH_REBUILD_USER_VERSION

    def _must_not_run() -> str:
        raise AssertionError("second call took a backup — it did not early-return")

    assert store.migrate_rebuild_graph_tables(backup=_must_not_run) is False


def test_in_transaction_verification_runs_while_both_tables_coexist(pre_pr8_graph):
    """8.8 — verification happens BEFORE `DROP`/`RENAME`/`COMMIT`.

    Verifying after the rename verifies nothing: the evidence — the old table
    — is already gone. Asserted by observing, from inside the verification
    call itself, that `nodes`/`nodes_new` and `edges`/`edges_new` all exist.
    """
    seen: dict[str, set[str]] = {}
    real_verify = store._rebuild_verify

    def _spy(tx):
        seen["tables"] = {
            r[0] for r in tx.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        return real_verify(tx)

    store._rebuild_verify = _spy
    try:
        store.migrate_rebuild_graph_tables(backup=_ok_backup)
    finally:
        store._rebuild_verify = real_verify
    assert {"nodes", "nodes_new", "edges", "edges_new"} <= seen["tables"]


def test_a_lost_row_makes_verification_raise_and_rolls_the_whole_thing_back(
    pre_pr8_graph,
):
    """8.9 — row-loss detectability, proven by ROLLBACK, not by a return value.

    Asserting that a check function returns False proves the function works.
    It does not prove the migration reacts to it. Here a row is genuinely
    dropped during the copy and the assertion is on the DATABASE afterwards:
    the OLD schema fully intact, unmigrated, with every row still present.
    """
    c = store._connect()
    ids = pre_pr8_graph["nodes"]
    nodes_before = c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    indexes_before = _index_names("nodes") | _index_names("edges")
    real_copy = store._rebuild_copy_rows

    def _lossy_copy(tx):
        real_copy(tx)
        tx.execute("DELETE FROM nodes_new WHERE id = ?", (ids["ana"],))

    store._rebuild_copy_rows = _lossy_copy
    try:
        with pytest.raises(RuntimeError) as exc:
            store.migrate_rebuild_graph_tables(backup=_ok_backup)
    finally:
        store._rebuild_copy_rows = real_copy
    assert "nodes" in str(exc.value)

    assert "from_id" in _cols("edges"), "the OLD schema must survive intact"
    assert "kind" in _cols("edges")
    assert c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0] == nodes_before
    assert c.execute(
        "SELECT label FROM nodes WHERE id=?", (ids["ana"],)
    ).fetchone()["label"] == "Ana Ríos"
    assert _index_names("nodes") | _index_names("edges") == indexes_before
    assert c.execute("PRAGMA user_version").fetchone()[0] == 0
    assert "nodes_new" not in {
        r[0] for r in c.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }


def test_a_dropped_embedding_makes_verification_raise_and_rolls_back(pre_pr8_graph):
    """The rebuild's most dangerous invited edit, turned into a rollback.

    axi's `nodes` carries `embedding`/`embedding_model`/`embedding_dim`; mobile
    has no embedder. Task 8.7 says "mobile's exact DDL", so the one change this
    migration invites is to make the columns match — which deletes every vector
    in the graph, taking recall and the whole RAG path with it. No error, no
    failing test: the rows are all there, the ids all match, only the meaning
    is gone.

    Verification originally compared uuid/kind/label/data/created_at/deleted_at
    and nothing else, so it could not have noticed. This simulates the loss the
    way 8.9 simulates row loss — really drop the column's contents mid-copy —
    and asserts on the DATABASE afterwards, not on a return value.
    """
    c = store._connect()
    ids = pre_pr8_graph["nodes"]
    before = c.execute(
        "SELECT length(embedding), embedding_model FROM nodes WHERE id=?", (ids["fact"],)
    ).fetchone()
    assert before[0] and before[1], "fixture seeds no embedding; this test proves nothing"
    real_copy = store._rebuild_copy_rows

    def _embedding_losing_copy(tx):
        real_copy(tx)
        # Exactly what a verbatim mobile DDL produces: rows present, vectors gone.
        tx.execute("UPDATE nodes_new SET embedding=NULL, embedding_model=NULL")

    store._rebuild_copy_rows = _embedding_losing_copy
    try:
        with pytest.raises(RuntimeError) as exc:
            store.migrate_rebuild_graph_tables(backup=_ok_backup)
    finally:
        store._rebuild_copy_rows = real_copy
    # Names the offending row, not just "something went wrong" — the same
    # diagnostic-quality rule task 6a.8 applied to the convergence guard.
    assert "node" in str(exc.value)
    assert str(ids["fact"]) in str(exc.value), (
        "the failure does not name the node whose embedding was lost"
    )

    assert "from_id" in _cols("edges"), "the OLD schema must survive intact"
    after = c.execute(
        "SELECT length(embedding), embedding_model FROM nodes WHERE id=?", (ids["fact"],)
    ).fetchone()
    assert after[0] == before[0], "the embedding did not survive the rollback"
    assert after[1] == before[1]
    assert c.execute("PRAGMA user_version").fetchone()[0] == 0


def test_a_killed_process_mid_rebuild_leaves_the_old_schema_unmigrated(pre_pr8_graph):
    """8.14 — a kill between `BEGIN IMMEDIATE` and `COMMIT` (simulated with a
    raise, not by killing the interpreter) rolls back to the intact old schema,
    and restarting is a clean retry gated by `PRAGMA user_version`."""
    c = store._connect()
    real_verify = store._rebuild_verify

    def _die(tx):
        raise KeyboardInterrupt("simulated SIGINT mid-rebuild")

    store._rebuild_verify = _die
    try:
        with pytest.raises(KeyboardInterrupt):
            store.migrate_rebuild_graph_tables(backup=_ok_backup)
    finally:
        store._rebuild_verify = real_verify

    assert "from_id" in _cols("edges")
    assert c.execute("PRAGMA user_version").fetchone()[0] == 0
    # Clean retry: the same call now completes.
    assert store.migrate_rebuild_graph_tables(backup=_ok_backup) is True
    assert "from_id" not in _cols("edges")
    assert c.execute("PRAGMA user_version").fetchone()[0] == \
        store.GRAPH_REBUILD_USER_VERSION


def test_node_id_foreign_keys_still_resolve_after_the_rebuild(pre_pr8_graph):
    """8.11 — `conversations.node_id` and `meetings.node_id` (and every other
    table pointing at `nodes.id`) still resolve, because the copy carried the
    ids explicitly instead of letting AUTOINCREMENT reassign them."""
    c = store._connect()
    nid = pre_pr8_graph["nodes"]["fact"]
    c.execute(
        "INSERT INTO conversations(ts, user_text, axi_text, node_id) "
        "VALUES (?, ?, ?, ?)", (1000.0, "hola", "hola", nid),
    )
    c.execute(
        "INSERT INTO meetings(start_time, data_dir, status, node_id, created_at) "
        "VALUES (?, ?, ?, ?, ?)", (1000.0, "/tmp/m", "done", nid, 1000.0),
    )

    store.migrate_rebuild_graph_tables(backup=_ok_backup)

    assert c.execute("PRAGMA foreign_key_check").fetchall() == []
    joined = c.execute(
        "SELECT n.label FROM conversations cv JOIN nodes n ON n.id = cv.node_id"
    ).fetchone()
    assert joined["label"] == "hipertensión diagnosticada"
    joined = c.execute(
        "SELECT n.label FROM meetings m JOIN nodes n ON n.id = m.node_id"
    ).fetchone()
    assert joined["label"] == "hipertensión diagnosticada"


def test_rebuild_tightens_the_constraints_to_mobiles_ddl(pre_pr8_graph):
    """8.12 — not just column PRESENCE: `uuid NOT NULL UNIQUE` and
    `lamport NOT NULL DEFAULT 0`, enforced by the engine."""
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    c = store._connect()

    for table in ("nodes", "edges"):
        info = {r[1]: r for r in c.execute(f"PRAGMA table_xinfo({table})").fetchall()}
        assert info["uuid"][3] == 1, f"{table}.uuid must be NOT NULL"
        assert info["lamport"][3] == 1, f"{table}.lamport must be NOT NULL"
        assert str(info["lamport"][4]) == "0", f"{table}.lamport must DEFAULT 0"
    for col in ("src_uuid", "dst_uuid", "relation", "updated_at"):
        info = {r[1]: r for r in c.execute("PRAGMA table_xinfo(edges)").fetchall()}
        assert info[col][3] == 1, f"edges.{col} must be NOT NULL (mobile's DDL)"

    # UNIQUE is real, not decorative.
    u = c.execute("SELECT uuid FROM nodes LIMIT 1").fetchone()[0]
    with pytest.raises(Exception):
        c.execute(
            "INSERT INTO nodes(uuid, kind, label, created_at, updated_at) "
            "VALUES (?, 'fact', 'dup', 1.0, 1.0)", (u,),
        )
    # NOT NULL is real too — this is what makes the raw-INSERT test fixtures
    # that skipped `uuid` fail HARD instead of being quietly wrong.
    with pytest.raises(Exception):
        c.execute(
            "INSERT INTO nodes(kind, label, created_at, updated_at) "
            "VALUES ('fact', 'sin uuid', 1.0, 1.0)"
        )
    # lamport defaults rather than nulls.
    assert {r[0] for r in c.execute("SELECT lamport FROM nodes").fetchall()} == {0}


def test_any_sql_still_naming_the_old_columns_fails_loudly(pre_pr8_graph):
    """8.13 — the silent-mis-assignment failure mode becomes a hard error by
    construction. Asserted directly rather than assumed.

    This is a BACKSTOP, not the enumeration: it only fires for SQL that
    actually executes. The enumeration of every site naming these columns is
    what stops a query from being missed in the first place.
    """
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    c = store._connect()
    for sql in (
        "SELECT from_id FROM edges",
        "SELECT to_id FROM edges",
        "SELECT e.kind FROM edges e",
        "SELECT 1 FROM edges WHERE from_id = 1 AND to_id = 2 AND kind = 'x'",
    ):
        with pytest.raises(Exception) as exc:
            c.execute(sql).fetchall()
        assert "no such column" in str(exc.value).lower(), sql


def test_rebuild_restores_the_indexes_the_drop_destroyed(pre_pr8_graph):
    """DROP TABLE takes every index on that table with it, and the RENAME does
    not bring them back. Measured, not assumed (probe: after DROP/RENAME the
    only index left on `nodes` was the implicit UNIQUE one).

    Without this the graph browser and the recall hot path silently degrade to
    full table scans: every answer still correct, no test failing, just slower
    forever — the exact defect shape this chain has already met three times.
    """
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    assert {"idx_nodes_kind", "idx_nodes_domain", "idx_nodes_created",
            "idx_nodes_deleted"} <= _index_names("nodes")
    assert {"idx_edges_src", "idx_edges_dst", "idx_edges_relation",
            "idx_edges_deleted"} <= _index_names("edges")
    # The three indexes on the columns that no longer exist are gone with them.
    assert {"idx_edges_from", "idx_edges_to", "idx_edges_kind"}.isdisjoint(
        _index_names("edges")
    )


def test_the_tombstone_indexes_stay_partial_after_the_rebuild(pre_pr8_graph):
    """The deliberate, documented divergence from mobile's DDL survives PR8.

    Mobile's index is unconditional; axi's carries `WHERE deleted_at IS NOT
    NULL`. PR8 copies mobile's DDL and is exactly where someone restores the
    symmetry. Measured in PR7: a FULL index on `deleted_at` gets chosen for
    the `deleted_at IS NULL` filter every read now carries, and since nearly
    every row is NULL that "SEARCH" walks the whole table. Name and column
    match mobile; only the predicate differs, and an index predicate is a
    local planner concern, not a wire contract.
    """
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    c = store._connect()
    for name in ("idx_nodes_deleted", "idx_edges_deleted"):
        sql = c.execute(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name=?", (name,)
        ).fetchone()[0]
        assert "WHERE deleted_at IS NOT NULL" in sql, name


def test_rebuild_restores_the_vec_cleanup_trigger(pre_pr8_graph):
    """`trg_nodes_delete_vec` is an AFTER DELETE trigger ON nodes, so
    `DROP TABLE nodes` destroys it and the RENAME does not restore it.

    `init_db()` calls `create_vec_nodes_table` BEFORE the migrations, so
    nothing would put it back until the NEXT startup — a window in which a
    hard node delete leaves an orphan embedding behind. Restored inside the
    migration instead of relying on call ordering.
    """
    c = store._connect()
    had_trigger = c.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' "
        "AND name='trg_nodes_delete_vec'"
    ).fetchone()[0]
    if not had_trigger:
        pytest.skip("sqlite-vec unavailable in this environment")
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    assert c.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' "
        "AND name='trg_nodes_delete_vec'"
    ).fetchone()[0] == 1


def test_rebuild_leaves_the_fts_index_intact(pre_pr8_graph):
    """`nodes_fts` addresses nodes by rowid. The explicit id copy is what keeps
    those rowids pointing at the same memories; a reassigning AUTOINCREMENT
    would silently re-attach every search hit to a different node."""
    ids = pre_pr8_graph["nodes"]
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    c = store._connect()
    row = c.execute(
        "SELECT n.id, n.label FROM nodes_fts f JOIN nodes n ON n.id = f.rowid "
        "WHERE nodes_fts MATCH 'hipertension'"
    ).fetchone()
    assert row["id"] == ids["fact"]
    assert row["label"] == "hipertensión diagnosticada"


def test_production_writers_speak_the_new_shape_end_to_end(pre_pr8_graph):
    """The rebuild is only half the contract: after it, `add_node`/`add_edge`
    must still work — against a table whose `uuid` is NOT NULL and whose
    endpoint columns are the uuids. Nothing in the delete/read paths may have
    been left addressing the columns that are gone."""
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    a = store.add_node("person", "Nuevo")
    b = store.add_node("fact", "algo nuevo")
    e = store.add_edge(a, b, "about")
    c = store._connect()
    row = c.execute(
        "SELECT uuid, src_uuid, dst_uuid, relation, updated_at, lamport "
        "FROM edges WHERE id=?", (e,)
    ).fetchone()
    assert row["uuid"] is not None
    assert row["src_uuid"] == c.execute(
        "SELECT uuid FROM nodes WHERE id=?", (a,)).fetchone()[0]
    assert row["relation"] == "about"
    assert row["updated_at"] is not None
    # Used to assert `lamport == 0`, which was true only while NOTHING wrote the
    # column. Slice 3a starts the clock: a row written by a production writer
    # now carries a real Lamport value and this device's origin, and a 0 here
    # would mean conflict resolution has nothing to order by — the exact
    # silent-data-loss failure the stamping exists to prevent.
    assert row["lamport"] > 0
    origin = c.execute(
        "SELECT origin_node FROM edges WHERE id=?", (e,)
    ).fetchone()["origin_node"]
    assert origin is not None
    assert store.delete_node(a) is True
    assert store.get_node(a) is None
    store.verify_edge_endpoint_convergence()
    # The delete tombstoned the edge along with the node, and a tombstoned edge
    # is never reported — otherwise every deletion the user ever made would
    # bury the real findings. No FK exists any more to have cascaded it away.
    assert store.report_dangling_edges() == []


def test_rebuilt_tables_keep_the_index_plans_the_graph_reads_depend_on(pre_pr8_graph):
    """The measurement, on a REBUILT database rather than a fresh one.

    Every previous index test in this chain runs against `_SCHEMA`'s fresh DDL.
    The owner's database does not take that path — it takes the rebuild, which
    creates its own indexes after `DROP TABLE` destroyed the originals. If that
    list ever drifts from `_SCHEMA`'s, every graph read on the ONE database
    that matters degrades to a full scan while every test stays green.

    Measured WITHOUT `ANALYZE`, because `store.py` never runs it and with it
    the planner behaves differently — measuring a configuration that does not
    ship proves nothing.

    "SEARCH not SCAN" is asserted together with the index NAME, deliberately:
    a SEARCH on a near-constant column is a full scan wearing an index's name,
    which is exactly how the tombstone-index defect hid in PR7.
    """
    store.migrate_rebuild_graph_tables(backup=_ok_backup)
    c = store._connect()
    node_uuid = pre_pr8_graph["uuids"]["hub"]

    def plan(sql: str, params: tuple) -> str:
        return "\n".join(
            str(r[3]) for r in c.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()
        )

    p = plan("SELECT id FROM edges WHERE src_uuid = ? AND deleted_at IS NULL",
             (node_uuid,))
    assert "idx_edges_src" in p, p
    assert "SCAN edges" not in p, p
    assert "idx_edges_deleted" not in p, (
        "the tombstone index was chosen for the LIVE-row filter — that is the "
        "full-table scan the partial predicate exists to prevent: " + p
    )

    p = plan("SELECT id FROM edges WHERE (src_uuid = ? OR dst_uuid = ?) "
             "AND deleted_at IS NULL", (node_uuid, node_uuid))
    assert "idx_edges_src" in p and "idx_edges_dst" in p, p
    assert "SCAN edges" not in p, p

    p = plan("SELECT id FROM edges WHERE relation = ? AND deleted_at IS NULL",
             ("about",))
    assert "idx_edges_relation" in p, p

    # …and the query the partial index is actually FOR (the sync push).
    p = plan("SELECT id FROM edges WHERE deleted_at IS NOT NULL", ())
    assert "idx_edges_deleted" in p, p
