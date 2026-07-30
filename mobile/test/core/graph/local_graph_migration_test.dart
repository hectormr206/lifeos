// TIMEOUT, calibrated not padded. These cases perform real cryptographic work
// (AES-GCM or SQLCipher) against a real temp directory: ~3 s on an idle
// machine, and repeatedly past the framework's generic 30 s default on the
// Proxmox runner.
//
// The cause is that runner, not this code. It is a Ryzen 5 5500U — a low-power
// mobile part with 6 physical cores — carrying twelve runner listeners for nine
// repositories. Ruled out by measurement: core count and disk throughput
// (PR #165), and AES-NI, which both CI machines have and which differs by only
// 1.6x between them. What is left is single-thread speed under contention.
//
// An earlier version of this comment blamed contention on the VPS. These jobs
// do not run on the VPS.
//
// A genuine hang still fails here, two minutes later instead of thirty seconds.
// Every assertion is unchanged.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Migration-framework tests for the on-device graph DB (roadmap SLICE A2).
///
/// These run on the host VM against REAL file-backed sqlite via
/// `sqflite_common_ffi` (no device, no SQLCipher — the migration SQL is
/// identical on both backends). They exercise the SAME callbacks
/// (`graphOnCreate`/`graphOnUpgrade`/`graphOnDowngrade`) and the SAME guarded
/// open (`openGuardedGraphDatabase`) that production uses; only the factory and
/// the missing password differ.
///
/// THIS IS THE TEMPLATE FOR EVERY FUTURE SCHEMA BUMP: for a vN→vN+1 change,
/// copy `group('v1 → v2 migration …')`, seed real rows at vN, open through the
/// real migration path to vN+1, and assert every row + relationship survives.
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lifeos_graph_mig_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String dbPath() => '${tmp.path}/graph.db';

  // ── shared ffi wiring mirroring production's guarded open ────────────────

  Future<int?> peekVersion(String path) async {
    if (!await databaseFactoryFfi.databaseExists(path)) return null;
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      return await db.getVersion();
    } finally {
      await db.close();
    }
  }

  /// Opens through the exact production guard rail (peek → downgrade-refuse →
  /// backup → migrate → restore-on-failure), wired to the ffi factory.
  Future<Database> openGuarded(String path, {bool backup = true}) =>
      openGuardedGraphDatabase(
        path: path,
        peekVersion: () => peekVersion(path),
        openMigrating: () =>
            databaseFactoryFfi.openDatabase(path, options: graphOpenOptions()),
        backupBeforeMigrate: backup,
      );

  /// Creates a file-backed DB pinned at an OLD schema [version] with ONLY that
  /// version's schema materialised (via [buildSchema]), then closes it. This is
  /// how we manufacture "a device that installed an older app".
  Future<void> seedOldDatabase(
    String path,
    int version,
    Future<void> Function(Database db) buildSchema,
  ) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) => buildSchema(db),
      ),
    );
    await db.close();
  }

  /// A normalised fingerprint of every user table + index (name + DDL), so two
  /// schemas built by different routes can be compared for exact equality.
  Future<List<String>> schemaFingerprint(Database db) async {
    final rows = await db.query(
      'sqlite_master',
      columns: ['type', 'name', 'sql'],
      where: "name NOT LIKE 'sqlite_%'",
    );
    final out = rows
        .map((r) =>
            '${r['type']}|${r['name']}|'
            '${(r['sql'] as String?)?.replaceAll(RegExp(r'\s+'), ' ').trim()}')
        .toList()
      ..sort();
    return out;
  }

  group('v1 → v2 migration preserves ALL data (worked example / template)', () {
    test('every node, edge, and relationship survives with correct values',
        () async {
      final path = dbPath();

      // (a) Create a v1 DB with real seeded nodes + edges.
      await seedOldDatabase(path, 1, applyLocalGraphSchema);

      final seedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final seedStore = SqfliteLocalGraphStore(seedDb);
      final hector = await seedStore.createNode(
        kind: 'person',
        label: 'Héctor',
        data: {'role': 'user', 'n': 1},
        domain: 'home',
      );
      final meeting = await seedStore.createNode(
        kind: 'event',
        label: 'Standup',
        data: {'notes': 'daily'},
      );
      final aspirin = await seedStore.createNode(
        kind: 'fact',
        label: 'Aspirin 100mg',
        data: {'dose': 100},
      );
      final edge = await seedStore.createEdge(
        srcUuid: hector.uuid,
        dstUuid: meeting.uuid,
        relation: 'attended',
        data: {'weight': 3},
      );
      // A tombstoned row must survive the migration too.
      final doomed = await seedStore.createNode(kind: 'fact', label: 'old');
      await seedStore.softDeleteNode(doomed.uuid);
      await seedDb.close();

      // (b) Open through the REAL migration path to the current version.
      final db = await openGuarded(path);
      addTearDown(() => db.close());
      expect(await db.getVersion(), kLocalGraphSchemaVersion);
      expect(kLocalGraphSchemaVersion, greaterThanOrEqualTo(2));

      // (c) Assert every pre-existing row + relationship survived intact.
      final store = SqfliteLocalGraphStore(db);

      final h = await store.getNodeByUuid(hector.uuid);
      expect(h, isNotNull);
      expect(h!.label, 'Héctor');
      expect(h.kind, 'person');
      expect(h.domain, 'home');
      expect(h.data['role'], 'user');
      expect(h.data['n'], 1);
      expect(h.localId, hector.localId); // rowids preserved

      final m = await store.getNodeByUuid(meeting.uuid);
      expect(m!.data['notes'], 'daily');
      final a = await store.getNodeByUuid(aspirin.uuid);
      expect(a!.data['dose'], 100);

      // Relationship intact.
      final edges = await store.edgesForNode(hector.uuid);
      expect(edges.single.uuid, edge.uuid);
      expect(edges.single.dstUuid, meeting.uuid);
      expect(edges.single.relation, 'attended');
      expect(edges.single.data['weight'], 3);
      final hop = await store.neighbors(hector.uuid);
      expect(hop.single.uuid, meeting.uuid);

      // Tombstone preserved (hidden normally, visible to sync).
      expect(await store.getNodeByUuid(doomed.uuid), isNull);
      final rawDoomed =
          await store.getNodeByUuid(doomed.uuid, includeDeleted: true);
      expect(rawDoomed!.isDeleted, isTrue);

      // (d) New v2 column exists with a sensible default (NULL) on old rows.
      final raw = await db.query(kNodesTable,
          columns: ['salience'], where: 'uuid = ?', whereArgs: [hector.uuid]);
      expect(raw.single.containsKey('salience'), isTrue);
      expect(raw.single['salience'], isNull);

      // (e) New v2 indexes exist.
      final idx = await db.query('sqlite_master',
          columns: ['name'], where: "type = 'index'");
      final names = idx.map((r) => r['name']).toSet();
      expect(names, containsAll(['idx_nodes_updated', 'idx_edges_updated']));
    });

    test('backup-before-migrate leaves a recoverable .bak of the pre-v2 file',
        () async {
      final path = dbPath();
      await seedOldDatabase(path, 1, applyLocalGraphSchema);
      final seedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final n = await SqfliteLocalGraphStore(seedDb)
          .createNode(kind: 'fact', label: 'keep-me');
      await seedDb.close();

      final db = await openGuarded(path);
      addTearDown(() => db.close());

      // A .bak was written before the upgrade and still holds the v1 data.
      final backupPath = '$path$kGraphBackupSuffix';
      expect(await File(backupPath).exists(), isTrue);

      final bak = await databaseFactoryFfi.openDatabase(
        backupPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(() => bak.close());
      expect(await bak.getVersion(), 1); // pre-migration version
      final backedUp = await SqfliteLocalGraphStore(bak).getNodeByUuid(n.uuid);
      expect(backedUp!.label, 'keep-me');
    });

    test('a fresh install can be created and reopened without backup', () async {
      final path = dbPath();
      // No pre-existing file → onCreate, no upgrade, no .bak.
      final db = await openGuarded(path);
      addTearDown(() => db.close());
      expect(await db.getVersion(), kLocalGraphSchemaVersion);
      expect(await File('$path$kGraphBackupSuffix').exists(), isFalse);
    });
  });

  group('v2 → v3 migration preserves ALL data and adds vec_nodes', () {
    // Build the v2 schema (frozen v1 base + the v2 migration) so we can
    // manufacture "a device that installed the v2 app".
    Future<void> buildV2Schema(Database db) async {
      await applyLocalGraphSchema(db);
      await runGraphMigrations(db, 1, 2);
    }

    test('every v2 node, edge, relationship + salience survives; vec_nodes works',
        () async {
      final path = dbPath();

      // (a) Create a v2 DB with real seeded rows, including a v2-only salience.
      await seedOldDatabase(path, 2, buildV2Schema);

      final seedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final seedStore = SqfliteLocalGraphStore(seedDb);
      final hector = await seedStore.createNode(
        kind: 'person',
        label: 'Héctor',
        data: {'role': 'user', 'n': 1},
        domain: 'home',
      );
      final meeting =
          await seedStore.createNode(kind: 'event', label: 'Standup');
      final edge = await seedStore.createEdge(
        srcUuid: hector.uuid,
        dstUuid: meeting.uuid,
        relation: 'attended',
        data: {'weight': 3},
      );
      // Set the v2-only salience column on a row to prove it survives v3.
      await seedDb.update('nodes', {'salience': 0.42},
          where: 'uuid = ?', whereArgs: [hector.uuid]);
      final doomed = await seedStore.createNode(kind: 'fact', label: 'old');
      await seedStore.softDeleteNode(doomed.uuid);
      await seedDb.close();

      // (b) Open through the REAL migration path to the current version (v3).
      final db = await openGuarded(path);
      addTearDown(() => db.close());
      expect(await db.getVersion(), kLocalGraphSchemaVersion);
      expect(kLocalGraphSchemaVersion, greaterThanOrEqualTo(3));

      // (c) Every pre-existing row + relationship survived intact.
      final store = SqfliteLocalGraphStore(db);
      final h = await store.getNodeByUuid(hector.uuid);
      expect(h, isNotNull);
      expect(h!.label, 'Héctor');
      expect(h.data['role'], 'user');
      expect(h.localId, hector.localId); // rowids preserved
      final edges = await store.edgesForNode(hector.uuid);
      expect(edges.single.uuid, edge.uuid);
      expect(edges.single.data['weight'], 3);
      // v2 salience value preserved byte-for-byte across the v3 upgrade.
      final salRow = await db.query('nodes',
          columns: ['salience'], where: 'uuid = ?', whereArgs: [hector.uuid]);
      expect(salRow.single['salience'], 0.42);
      // Tombstone preserved.
      expect(await store.getNodeByUuid(doomed.uuid), isNull);

      // (d) New v3 vec_nodes table exists and is immediately usable: index the
      // surviving node's vector and recall it back.
      await store.upsertNodeVector(
          hector.uuid, 'm@3', 3, Float32List.fromList([1, 0, 0]));
      final hits =
          await store.recall(Float32List.fromList([1, 0, 0]), k: 1, model: 'm@3');
      expect(hits.single.uuid, hector.uuid);

      // (e) The v3 index exists.
      final idx = await db.query('sqlite_master',
          columns: ['name'], where: "type = 'index'");
      final names = idx.map((r) => r['name']).toSet();
      expect(names, contains('idx_vec_nodes_model'));
    });
  });

  group('onCreate and cumulative onUpgrade converge to an IDENTICAL schema', () {
    test('fresh-latest schema == v1-base-then-upgrade schema', () async {
      // Route A: fresh install → onCreate builds the latest schema.
      final freshPath = '${tmp.path}/fresh.db';
      final fresh = await openGuarded(freshPath);
      addTearDown(() => fresh.close());
      final fingerprintFresh = await schemaFingerprint(fresh);

      // Route B: install at v1 base, then upgrade through onUpgrade.
      final upgradedPath = '${tmp.path}/upgraded.db';
      await seedOldDatabase(upgradedPath, 1, applyLocalGraphSchema);
      final upgraded = await openGuarded(upgradedPath);
      addTearDown(() => upgraded.close());
      final fingerprintUpgraded = await schemaFingerprint(upgraded);

      expect(fingerprintUpgraded, equals(fingerprintFresh));
      // Sanity: the fingerprint actually contains the v2 additions.
      expect(
        fingerprintFresh.any((s) => s.contains('idx_nodes_updated')),
        isTrue,
      );
    });
  });

  group('non-destructive guard rails', () {
    test('additive-only guardrail rejects destructive statements', () {
      expect(
        () => assertAdditiveMigrationStatement(9, 'DROP TABLE $kNodesTable'),
        throwsA(isA<GraphMigrationException>()),
      );
      expect(
        () => assertAdditiveMigrationStatement(
            9, 'DELETE FROM $kNodesTable WHERE 1=1'),
        throwsA(isA<GraphMigrationException>()),
      );
      expect(
        () => assertAdditiveMigrationStatement(
            9, 'ALTER TABLE $kNodesTable RENAME TO old_nodes'),
        throwsA(isA<GraphMigrationException>()),
      );
      // Additive statements pass.
      expect(
        () => assertAdditiveMigrationStatement(
            9, 'ALTER TABLE $kNodesTable ADD COLUMN foo TEXT'),
        returnsNormally,
      );
      expect(
        () => assertAdditiveMigrationStatement(
            9, 'CREATE INDEX idx_foo ON $kNodesTable(foo)'),
        returnsNormally,
      );
    });

    test('every shipped migration contains only additive statements', () {
      for (final m in kGraphMigrations) {
        for (final s in m.statements) {
          expect(() => assertAdditiveMigrationStatement(m.version, s),
              returnsNormally,
              reason: 'v${m.version}: $s');
        }
      }
    });

    test('opening a NEWER database is refused and leaves the file intact',
        () async {
      final path = dbPath();
      // Manufacture a DB from a hypothetical future app version.
      final futureVersion = kLocalGraphSchemaVersion + 1;
      await seedOldDatabase(path, futureVersion, createLatestGraphSchema);
      final seedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final n = await SqfliteLocalGraphStore(seedDb)
          .createNode(kind: 'fact', label: 'future-data');
      await seedDb.close();

      // Guarded open must throw rather than migrate/wipe.
      await expectLater(
        openGuarded(path),
        throwsA(isA<GraphMigrationException>()),
      );

      // The file is untouched: still present, still at the future version,
      // with the row intact. No empty DB was created in its place.
      expect(await File(path).exists(), isTrue);
      expect(await peekVersion(path), futureVersion);
      final check = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(() => check.close());
      final survived =
          await SqfliteLocalGraphStore(check).getNodeByUuid(n.uuid);
      expect(survived!.label, 'future-data');
    });
  });
}
