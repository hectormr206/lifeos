/// DDL for the on-device property-graph store (roadmap SLICE A2).
///
/// Ported from `axi/src/axi/store.py`'s SQLCipher property-graph: `nodes`
/// (entities/facts/events) + `edges` (relationships). This is the CORE graph
/// shape only — the vec/FTS5 extensions (`nodes_fts`, `vec_nodes`) and the
/// per-domain structured tables land in a later slice (B1).
///
/// Two deliberate departures from store.py, both to make the store
/// sync-ready NOW so we avoid a painful migration once multi-device sync
/// lands (PRD D1):
///
///  * Every row carries a `uuid` (the stable, globally-unique **sync** id),
///    `origin_node` (which device/replica authored the row), `lamport` (a
///    logical clock for last-writer-wins conflict resolution), and
///    `deleted_at` (a nullable tombstone — rows are soft-deleted so a delete
///    can propagate to other replicas instead of resurrecting on the next
///    sync).
///  * Edges reference nodes by `uuid` (`src_uuid`/`dst_uuid`), NOT by local
///    autoincrement rowid. Local rowids differ per device; uuids are stable
///    across replicas, so an edge synced from another device still resolves.
///
/// `label` is store.py's node "subject/title"; `data` is its JSON prop/body
/// blob. `relation` is store.py's edge `kind` (renamed to match
/// `lifeos/src/lifeos/edges.py`'s `rel` model and avoid overloading "kind"
/// across the two tables).
library;

import 'package:sqflite_sqlcipher/sqflite.dart';

/// Current on-disk schema version. Bumped for EVERY schema change; drives the
/// `onCreate`/`onUpgrade` migration framework in `local_graph_migrations.dart`.
///
/// MIGRATION DISCIPLINE (data-safety-critical — the app auto-updates via OTA):
///   Do NOT edit the v1 DDL below to add new columns/tables. That DDL is the
///   FROZEN v1 base every installed device started from. To change the schema:
///     1. Append ONE additive step to `kGraphMigrations` (ADD COLUMN / CREATE
///        TABLE / CREATE INDEX / backfill — NEVER DROP/DELETE/TRUNCATE/rename).
///     2. Bump this constant.
///     3. Add a vN→vN+1 data-survival test.
///   See `MIGRATIONS.md` next to this file for the full protocol.
const int kLocalGraphSchemaVersion = 3;

const String kNodesTable = 'nodes';
const String kEdgesTable = 'edges';

/// Vector sidecar table (added in v3 — see `kGraphMigrations`). Holds one
/// on-device embedding per (node, model) for brute-force cosine RAG recall
/// (roadmap SLICE B1). It is NOT part of the frozen v1 base — the CREATE TABLE
/// lives in the v3 migration step so existing devices gain it additively.
const String kVecNodesTable = 'vec_nodes';

const String _createNodesTable = '''
CREATE TABLE IF NOT EXISTS $kNodesTable (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- local rowid (per-device)
  uuid         TEXT    NOT NULL UNIQUE,             -- sync primary id (stable across replicas)
  kind         TEXT    NOT NULL,                    -- 'person'|'fact'|'event'|'conversation'|...
  label        TEXT    NOT NULL,                    -- short human-readable subject/title
  data         TEXT,                                -- JSON blob of type-specific props/body
  domain       TEXT,                                -- 'health'|'finance'|'work'|... or NULL
  occurred_at  REAL,                                -- real event time (Unix epoch UTC), NULL if unknown
  created_at   REAL    NOT NULL,                    -- graph-insertion time (Unix epoch UTC)
  updated_at   REAL    NOT NULL,
  created_tz   TEXT,                                -- IANA tz active when the node was created
  origin_node  TEXT,                                -- sync: replica/device that authored this row
  lamport      INTEGER NOT NULL DEFAULT 0,          -- sync: logical clock for LWW conflict resolution
  deleted_at   REAL                                 -- sync: tombstone (NULL = live row)
)
''';

const String _createEdgesTable = '''
CREATE TABLE IF NOT EXISTS $kEdgesTable (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,   -- local rowid (per-device)
  uuid         TEXT    NOT NULL UNIQUE,             -- sync primary id
  src_uuid     TEXT    NOT NULL,                    -- source node.uuid (NOT rowid — stable across replicas)
  dst_uuid     TEXT    NOT NULL,                    -- destination node.uuid
  relation     TEXT    NOT NULL,                    -- 'mentioned_in'|'caused_by'|'belongs_to'|...
  data         TEXT,                                -- JSON props
  created_at   REAL    NOT NULL,
  updated_at   REAL    NOT NULL,
  origin_node  TEXT,                                -- sync: authoring replica
  lamport      INTEGER NOT NULL DEFAULT 0,          -- sync: logical clock
  deleted_at   REAL                                 -- sync: tombstone (NULL = live edge)
)
''';

const List<String> _indexes = <String>[
  'CREATE INDEX IF NOT EXISTS idx_nodes_kind      ON $kNodesTable(kind)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_domain    ON $kNodesTable(domain)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_created   ON $kNodesTable(created_at)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_deleted   ON $kNodesTable(deleted_at)',
  // uuid already gets a UNIQUE index from the column constraint.
  'CREATE INDEX IF NOT EXISTS idx_edges_src       ON $kEdgesTable(src_uuid)',
  'CREATE INDEX IF NOT EXISTS idx_edges_dst       ON $kEdgesTable(dst_uuid)',
  'CREATE INDEX IF NOT EXISTS idx_edges_relation  ON $kEdgesTable(relation)',
  'CREATE INDEX IF NOT EXISTS idx_edges_deleted   ON $kEdgesTable(deleted_at)',
];

/// Materialise the FROZEN v1 base schema. This is the historical starting
/// point of every device that ever installed the app; it must NEVER be edited
/// to add v2+ columns/tables — those go through `kGraphMigrations` instead.
/// Fresh installs get the latest schema via `createLatestGraphSchema` (base +
/// migrations), so callers should prefer that; this remains public for the
/// store unit tests that exercise the v1 shape directly.
/// Idempotent (`IF NOT EXISTS` throughout) so it is safe to call on every
/// open as a belt-and-braces guard.
Future<void> applyLocalGraphSchema(DatabaseExecutor db) async {
  await db.execute(_createNodesTable);
  await db.execute(_createEdgesTable);
  for (final statement in _indexes) {
    await db.execute(statement);
  }
}
