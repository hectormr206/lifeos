"""Upgrading a database older than every migration in this chain.

WHY THIS FILE EXISTS. Every other fixture in this suite builds its "legacy"
database with code that already carried PR4's sync columns, so they all start
too late. Héctor's real database predates the entire chain: its `edges` table
is `(id, from_id, to_id, kind, data, created_at)` and its `nodes` has no
`uuid`, no `lamport`, no `deleted_at`.

Run against that, `init_db()` died on its very first statement —
`executescript(_SCHEMA)` — with `no such column: uuid`, because `_SCHEMA`
carried `CREATE INDEX` statements over columns that only the MIGRATIONS add.
On a fresh database the `CREATE TABLE` supplies them and everything passes; on
a genuinely old one `CREATE TABLE IF NOT EXISTS` is a no-op and the index
cannot be built.

It failed safely — before any migration, before the rebuild, with the graph
untouched — but it failed every time, so the daemon could never have started
on the machine this whole chain was written for.
"""
from __future__ import annotations

from axi import store

# Verbatim from the real pre-chain database, read off `PRAGMA table_xinfo`.
_ORIGINAL_NODES = """
CREATE TABLE nodes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,
  label      TEXT NOT NULL,
  data       TEXT,
  domain     TEXT,
  created_at REAL,
  updated_at REAL,
  created_tz TEXT
);
"""
_ORIGINAL_EDGES = """
CREATE TABLE edges (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  from_id    INTEGER NOT NULL,
  to_id      INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  data       TEXT,
  created_at REAL
);
"""


def _rewind_to_the_original_schema() -> tuple[int, int]:
    """Replace nodes/edges with their pre-chain shape and seed real-ish rows."""
    c = store._connect()
    c.execute("PRAGMA foreign_keys=OFF")
    c.execute("DROP TABLE IF EXISTS edges")
    c.execute("DROP TABLE IF EXISTS nodes")
    c.executescript(_ORIGINAL_NODES)
    c.executescript(_ORIGINAL_EDGES)
    c.execute("PRAGMA user_version = 0")
    now = 1_700_000_000.0
    for kind, label in (
        ("person", "Héctor"),
        ("fact", "presión 109/77, pulso 58"),
        ("fact", "báscula: grasa 15.5%"),
    ):
        c.execute(
            "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, "
            "created_tz) VALUES (?, ?, '{}', 'health', ?, ?, 'UTC')",
            (kind, label, now, now),
        )
    c.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at) "
        "VALUES (1, 2, 'about', '{}', ?)", (now,)
    )
    c.execute(
        "INSERT INTO edges(from_id, to_id, kind, data, created_at) "
        "VALUES (1, 3, 'about', '{}', ?)", (now,)
    )
    c.commit()
    return (
        c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0],
        c.execute("SELECT COUNT(*) FROM edges").fetchone()[0],
    )


def test_init_db_upgrades_a_pre_chain_database_without_dying():
    """The whole chain, applied to a database older than all of it."""
    n_before, e_before = _rewind_to_the_original_schema()

    store.init_db()          # this raised `no such column: uuid`

    c = store._connect()
    cols = {r[1] for r in c.execute("PRAGMA table_xinfo(edges)")}
    assert "from_id" not in cols, "the rebuild did not complete"
    assert {"src_uuid", "dst_uuid", "relation", "uuid"} <= cols
    assert c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0] == n_before
    assert c.execute("SELECT COUNT(*) FROM edges").fetchone()[0] == e_before
    assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"


def test_the_upgrade_preserves_the_actual_memories():
    """Counts matching is not the same as the user's memories being there."""
    _rewind_to_the_original_schema()

    store.init_db()

    labels = {
        r[0] for r in store._connect().execute("SELECT label FROM nodes")
    }
    assert "presión 109/77, pulso 58" in labels
    assert "báscula: grasa 15.5%" in labels


def test_every_index_survives_the_upgrade():
    """The statements moved out of `_SCHEMA` must still all exist afterwards —
    otherwise this fix trades a hard failure for a silent full-scan."""
    _rewind_to_the_original_schema()

    store.init_db()

    names = {
        r[0] for r in store._connect().execute(
            "SELECT name FROM sqlite_master WHERE type='index'"
        )
    }
    for expected in (
        "idx_nodes_uuid", "idx_nodes_deleted", "idx_edges_uuid",
        "idx_edges_src", "idx_edges_dst", "idx_edges_relation",
        "idx_edges_deleted",
    ):
        assert expected in names, f"{expected} was lost in the upgrade"
