/// Versioned, NON-DESTRUCTIVE migration framework for the on-device graph DB
/// (roadmap SLICE A2). This is the single source of truth for how the encrypted
/// local graph evolves across OTA app updates.
///
/// ─────────────────────────────────────────────────────────────────────────
/// THE RULE (read `MIGRATIONS.md` next to this file for the full protocol):
///   Every schema change = (1) append ONE [GraphMigration] step here, keyed by
///   the next version, and (2) add a vN→vN+1 data-survival test. Migrations are
///   ADDITIVE-ONLY. An OTA update must NEVER drop, truncate, delete, rename, or
///   recreate a user table/column. The user's graph/memory/RAG/config survives
///   every upgrade, byte for byte.
/// ─────────────────────────────────────────────────────────────────────────
///
/// How the framework fits together:
///
///  * [applyLocalGraphSchema] (in `local_graph_schema.dart`) is the FROZEN v1
///    base schema. It never changes again — it is the historical starting
///    point every device that ever installed the app began from.
///  * [kGraphMigrations] is the ordered list of steps for v2, v3, … Each step
///    is a set of additive SQL statements (+ an optional data backfill).
///  * [createLatestGraphSchema] (the `onCreate` path) builds the newest schema
///    by applying the v1 base and then replaying EVERY migration in order.
///  * [runGraphMigrations] (the `onUpgrade` path) replays only the steps a
///    given device is missing (oldVersion → newVersion).
///
/// Because `onCreate` == base + all migrations, and `onUpgrade` == the same
/// migrations, a fresh install and an upgraded install reach an IDENTICAL final
/// schema BY CONSTRUCTION. `local_graph_migration_test.dart` asserts this.
library;

import 'dart:io';

// The shared migration framework speaks the PLATFORM-NEUTRAL sqflite API, not
// the mobile-only `sqflite_sqlcipher` plugin. `sqflite_sqlcipher` (mobile) and
// `sqflite_common_ffi` (desktop) both implement these exact types, which is
// what lets a single copy of this framework serve both backends — see
// `graph_database_backend.dart`.
import 'package:sqflite_common/sqlite_api.dart';

import 'local_graph_schema.dart';

/// Thrown for any non-recoverable migration condition. It is ALWAYS surfaced —
/// the framework fails loudly and leaves the on-disk file intact rather than
/// wiping or recreating the user's data.
class GraphMigrationException implements Exception {
  GraphMigrationException(this.message);

  /// The app opened a database written by a NEWER app version. Downgrades are
  /// refused (never destroy data a newer app may depend on).
  factory GraphMigrationException.downgrade(int onDisk, int supported) =>
      GraphMigrationException(
        'On-disk graph DB is at schema v$onDisk but this app only supports '
        'v$supported. Refusing to open a newer database to avoid data loss — '
        'update the app instead. The existing file is left untouched.',
      );

  /// A migration statement was rejected for being destructive.
  factory GraphMigrationException.destructive(int version, String statement) =>
      GraphMigrationException(
        'Migration to v$version contains a DESTRUCTIVE statement, which is '
        'forbidden (migrations are additive-only): "$statement".',
      );

  final String message;

  @override
  String toString() => 'GraphMigrationException: $message';
}

/// A single, isolated, additive schema step. One per version bump.
///
/// [statements] run first (DDL: `ADD COLUMN` / `CREATE TABLE` / `CREATE INDEX`),
/// each validated against the additive-only guardrail. [backfill] then runs any
/// data population (e.g. computing a default for the freshly-added column). Both
/// execute inside sqflite's upgrade transaction, so a failure rolls back cleanly.
class GraphMigration {
  const GraphMigration({
    required this.version,
    required this.description,
    this.statements = const <String>[],
    this.backfill,
  });

  /// The schema version this step ADVANCES the DB TO (must be > 1 and unique).
  final int version;

  /// Human-readable summary of what this step adds (for logs + review).
  final String description;

  /// Additive DDL/DML statements. Validated by [assertAdditiveMigrationStatement].
  final List<String> statements;

  /// Optional data backfill run after [statements] (e.g. default new columns).
  final Future<void> Function(DatabaseExecutor db)? backfill;
}

/// ORDERED list of migration steps. APPEND-ONLY: never edit or reorder an
/// existing entry once shipped — that would rewrite history for devices that
/// already ran it. Add the next version at the end.
///
/// ── v2 (worked example) ──────────────────────────────────────────────────
/// Adds `nodes.salience` (a nullable relevance/decay weight, sensible default
/// NULL = "unranked" for all pre-existing rows) plus `updated_at` indexes on
/// both tables to make future sync delta-scans cheap. Purely additive: every
/// v1 node, edge, and relationship is preserved untouched.
///
/// ── v3 ───────────────────────────────────────────────────────────────────
/// Adds the `vec_nodes` sidecar table: one on-device embedding per
/// (node_uuid, model) for brute-force cosine RAG recall (roadmap SLICE B1).
/// `vec` is a float32 little-endian BLOB; `model`+`dim` are stored on EVERY row
/// so recall can filter to a single model and NEVER compare vectors across
/// models (caveat R8). Purely additive — a brand-new table plus its index; no
/// existing node/edge/relationship row is touched, so every v2 graph survives.
///
/// SYNC CAVEAT (R8): vectors are LOCAL-ONLY. Sync must transfer node *text*
/// (label/data) but NEVER these vector rows — each device re-embeds locally
/// with its own model so vectors are never mixed across models/devices.
const List<GraphMigration> kGraphMigrations = <GraphMigration>[
  GraphMigration(
    version: 2,
    description:
        'Add nullable nodes.salience + updated_at indexes on nodes and edges.',
    statements: <String>[
      'ALTER TABLE $kNodesTable ADD COLUMN salience REAL',
      'CREATE INDEX IF NOT EXISTS idx_nodes_updated ON $kNodesTable(updated_at)',
      'CREATE INDEX IF NOT EXISTS idx_edges_updated ON $kEdgesTable(updated_at)',
    ],
  ),
  GraphMigration(
    version: 3,
    description:
        'Add vec_nodes(node_uuid, model, dim, vec BLOB) sidecar + model index '
        'for on-device RAG recall. Vectors are local-only, never synced.',
    statements: <String>[
      'CREATE TABLE IF NOT EXISTS $kVecNodesTable ('
          '  node_uuid TEXT    NOT NULL,'
          '  model     TEXT    NOT NULL,'
          '  dim       INTEGER NOT NULL,'
          '  vec       BLOB    NOT NULL,'
          '  PRIMARY KEY (node_uuid, model)'
          ')',
      'CREATE INDEX IF NOT EXISTS idx_vec_nodes_model '
          'ON $kVecNodesTable(model)',
    ],
  ),
];

/// Destructive-statement guardrail. Rejects anything that could drop, delete,
/// truncate, or rename a user table/column. This is what makes "additive-only"
/// an ENFORCED invariant instead of a code-review hope.
final RegExp _destructivePattern = RegExp(
  r'\b(DROP|DELETE|TRUNCATE|REPLACE\s+INTO)\b|\bRENAME\s+(TO|COLUMN)\b',
  caseSensitive: false,
);

/// Throws [GraphMigrationException.destructive] if [statement] is not additive.
/// Called for every migration statement before it executes.
void assertAdditiveMigrationStatement(int version, String statement) {
  if (_destructivePattern.hasMatch(statement)) {
    throw GraphMigrationException.destructive(version, statement.trim());
  }
}

/// Replays every migration step whose version is in (fromVersion, toVersion].
/// Used by the `onUpgrade` path. Each statement is guardrail-checked first.
Future<void> runGraphMigrations(
  DatabaseExecutor db,
  int fromVersion,
  int toVersion,
) async {
  final pending = kGraphMigrations
      .where((m) => m.version > fromVersion && m.version <= toVersion)
      .toList()
    ..sort((a, b) => a.version.compareTo(b.version));

  for (final migration in pending) {
    for (final statement in migration.statements) {
      assertAdditiveMigrationStatement(migration.version, statement);
      await db.execute(statement);
    }
    await migration.backfill?.call(db);
  }
}

/// Builds the NEWEST schema on a fresh database: the frozen v1 base plus every
/// migration replayed in order. This is the `onCreate` path, and it is
/// deliberately the same route as `onUpgrade` so both converge identically.
Future<void> createLatestGraphSchema(DatabaseExecutor db) async {
  await applyLocalGraphSchema(db); // frozen v1 base
  await runGraphMigrations(db, 1, kLocalGraphSchemaVersion);
}

// ── sqflite open callbacks (shared by production + host tests) ──────────────

/// Enforce foreign keys on every connection.
Future<void> graphOnConfigure(Database db) async {
  await db.execute('PRAGMA foreign_keys = ON');
}

/// Fresh install → build the latest schema.
Future<void> graphOnCreate(Database db, int version) =>
    createLatestGraphSchema(db);

/// Existing install on an older schema → replay only the missing steps.
/// Runs inside sqflite's transaction, so a throw rolls the file back cleanly.
Future<void> graphOnUpgrade(Database db, int oldVersion, int newVersion) =>
    runGraphMigrations(db, oldVersion, newVersion);

/// A database from a NEWER app version. Refuse loudly; NEVER delete/recreate.
/// (This is the non-destructive analogue of `onDatabaseDowngradeDelete`, which
/// we must never use because it wipes the user's data.)
Future<void> graphOnDowngrade(Database db, int oldVersion, int newVersion) async {
  throw GraphMigrationException.downgrade(oldVersion, newVersion);
}

/// The canonical open options wiring version + all migration callbacks. Host
/// tests pass this to the ffi factory so they exercise the REAL migration path;
/// production adds the SQLCipher password on top of the same callbacks.
///
/// [onConfigure] overrides the per-connection configuration hook. The desktop
/// backend needs this seam because on `sqflite_common_ffi` the SQLCipher key is
/// not an open parameter — it is a `PRAGMA key` that has to be the FIRST
/// statement on the connection, i.e. inside `onConfigure`, before sqflite reads
/// `user_version`. An override MUST still call [graphOnConfigure] so foreign
/// keys stay enforced; `SqlCipherFfiGraphBackend` does.
OpenDatabaseOptions graphOpenOptions({OnDatabaseConfigureFn? onConfigure}) =>
    OpenDatabaseOptions(
      version: kLocalGraphSchemaVersion,
      onConfigure: onConfigure ?? graphOnConfigure,
      onCreate: graphOnCreate,
      onUpgrade: graphOnUpgrade,
      onDowngrade: graphOnDowngrade,
    );

// ── backup-before-migrate + guarded open ────────────────────────────────────

/// Backup file suffix. One rolling slot alongside the live DB.
const String kGraphBackupSuffix = '.bak';

/// Copies the at-rest DB file to `<path>$kGraphBackupSuffix` before an upgrade
/// runs, so a failed migration can be recovered. Returns the backup path, or
/// null if there was nothing to back up. Best-effort: a backup failure must not
/// block opening (the upgrade itself is still transactional).
Future<String?> backupGraphDatabaseFile(String path) async {
  final source = File(path);
  if (!await source.exists()) return null;
  final backupPath = '$path$kGraphBackupSuffix';
  try {
    await source.copy(backupPath);
    return backupPath;
  } catch (_) {
    return null;
  }
}

/// Restores a pre-migration backup over the live file. Used only when a
/// migration/open fails, to leave the user with their intact pre-upgrade data.
Future<void> restoreGraphDatabaseFile(String backupPath, String path) async {
  final backup = File(backupPath);
  if (!await backup.exists()) return;
  await backup.copy(path);
}

/// Opens the graph DB through the full non-destructive guard rail:
///
///  1. [peekVersion] reads the at-rest `user_version` WITHOUT migrating
///     (null ⇒ the file does not exist yet — a fresh install).
///  2. A newer-than-supported DB is REFUSED (downgrade guard) — the file is
///     left untouched; no empty DB is ever created in its place.
///  3. If an upgrade is pending, the file is copied to `.bak` first.
///  4. [openMigrating] performs the real keyed/migrating open.
///  5. If that throws, the `.bak` is restored and the error is rethrown — we
///     NEVER swallow the failure or hand back an empty database.
///
/// Both production and the host migration tests call this; only [peekVersion]
/// and [openMigrating] differ (SQLCipher+keystore vs ffi).
Future<Database> openGuardedGraphDatabase({
  required String path,
  required Future<int?> Function() peekVersion,
  required Future<Database> Function() openMigrating,
  bool backupBeforeMigrate = true,
}) async {
  final onDisk = await peekVersion();

  if (onDisk != null && onDisk > kLocalGraphSchemaVersion) {
    // Downgrade: fail closed, keep the existing file intact.
    throw GraphMigrationException.downgrade(onDisk, kLocalGraphSchemaVersion);
  }

  final upgradePending = onDisk != null && onDisk < kLocalGraphSchemaVersion;
  String? backupPath;
  if (backupBeforeMigrate && upgradePending) {
    backupPath = await backupGraphDatabaseFile(path);
  }

  try {
    return await openMigrating();
  } catch (_) {
    // Migration/decrypt/open failed. Restore the pre-migration file so the
    // user keeps their data, then surface the error. Do NOT create an empty DB.
    if (backupPath != null) {
      await restoreGraphDatabaseFile(backupPath, path);
    }
    rethrow;
  }
}
