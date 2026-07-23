// Proves the data-control BACKUP engine (part A) against a REAL file-backed
// sqlite database via sqflite_common_ffi (same SQL surface as the on-device
// SQLCipher backend — VACUUM INTO is standard SQLite, and on SQLCipher the
// copy keeps the source's encryption):
//   * createBackup produces a consistent, openable copy of the live DB;
//   * automatic backups rotate — only the newest `autoRetention` survive;
//   * maybeAutoBackup creates at most one automatic backup per day;
//   * restore is REVERSIBLE: the current state is snapshotted as a
//     pre-restore backup first, and restoring THAT snapshot returns to the
//     pre-restore data ("regresar a los datos actuales").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/data_control/data/graph_backup_service.dart';
import 'package:lifeos/features/data_control/domain/backup_info.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempRoot;
  late String dbPath;
  Database? db;
  late DateTime fakeNow;

  setUpAll(sqfliteFfiInit);

  Future<Database> openDb() async {
    db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: graphOpenOptions(),
    );
    return db!;
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-backup-test-');
    dbPath = '${tempRoot.path}/lifeos_graph.db';
    fakeNow = DateTime(2026, 7, 23, 9, 0);
    await openDb();
  });

  tearDown(() async {
    if (db!.isOpen) await db!.close();
    await tempRoot.delete(recursive: true);
  });

  GraphBackupService service({int autoRetention = 5}) => GraphBackupService(
    database: () async {
      if (!db!.isOpen) await openDb();
      return db!;
    },
    databasePath: () async => dbPath,
    backupsRoot: () async => Directory('${tempRoot.path}/backups'),
    suspendDatabase: () async {
      if (db!.isOpen) await db!.close();
    },
    resumeDatabase: () {},
    clock: () => fakeNow,
    autoRetention: autoRetention,
  );

  Future<List<String>> nodeLabels() async {
    final store = SqfliteLocalGraphStore(db!);
    final nodes = await store.listNodesByKind('fact');
    return nodes.map((n) => n.label).toList()..sort();
  }

  Future<void> addFact(String label) => SqfliteLocalGraphStore(
    db!,
  ).createNode(kind: 'fact', label: label).then((_) {});

  test(
    'createBackup writes a consistent, openable copy (VACUUM INTO)',
    () async {
      await addFact('presión 110/80');
      final backup = await service().createBackup(kind: BackupKind.manual);

      expect(File(backup.path).existsSync(), isTrue);
      expect(backup.sizeBytes, greaterThan(0));
      expect(backup.kind, BackupKind.manual);

      // The copy is a standalone, openable DB holding the same data.
      final copy = await databaseFactoryFfi.openDatabase(backup.path);
      final rows = await copy.query('nodes');
      await copy.close();
      expect(rows, hasLength(1));
      expect(rows.single['label'], 'presión 110/80');
    },
  );

  test(
    'automatic backups rotate: only the newest autoRetention survive',
    () async {
      final svc = service(autoRetention: 5);
      for (var i = 0; i < 7; i++) {
        fakeNow = fakeNow.add(const Duration(days: 1));
        await svc.createBackup(kind: BackupKind.auto);
      }
      final autos = (await svc.list())
          .where((b) => b.kind == BackupKind.auto)
          .toList();
      expect(autos, hasLength(5));
      // Newest-first listing: the two OLDEST were rotated out.
      final expectedNewest = fakeNow;
      expect(
        autos.first.createdAt.millisecondsSinceEpoch,
        expectedNewest.millisecondsSinceEpoch,
      );
    },
  );

  test(
    'maybeAutoBackup creates one per day, manual copies never rotate',
    () async {
      final svc = service();
      expect(await svc.maybeAutoBackup(), isTrue);
      // Same day again → no new backup.
      fakeNow = fakeNow.add(const Duration(hours: 3));
      expect(await svc.maybeAutoBackup(), isFalse);
      // Next day → a new one.
      fakeNow = fakeNow.add(const Duration(days: 1));
      expect(await svc.maybeAutoBackup(), isTrue);

      final all = await svc.list();
      expect(all.where((b) => b.kind == BackupKind.auto), hasLength(2));
    },
  );

  test('deleteBackup removes exactly that file', () async {
    final svc = service();
    final a = await svc.createBackup(kind: BackupKind.manual);
    fakeNow = fakeNow.add(const Duration(minutes: 1));
    final b = await svc.createBackup(kind: BackupKind.manual);

    await svc.deleteBackup(a);

    final remaining = await svc.list();
    expect(remaining.map((x) => x.path), [b.path]);
    expect(File(a.path).existsSync(), isFalse);
  });

  test(
    'restore is reversible: pre-restore snapshot leads back to current data',
    () async {
      final svc = service();

      // State 1: only "A".
      await addFact('A');
      final backup = await svc.createBackup(kind: BackupKind.manual);

      // State 2: "A" + "B".
      await addFact('B');
      expect(await nodeLabels(), ['A', 'B']);

      // Restore state 1 → the CURRENT state 2 is snapshotted first.
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      final preRestore = await svc.restoreBackup(backup);
      expect(preRestore.kind, BackupKind.preRestore);
      expect((await svc.list()).map((b) => b.path), contains(preRestore.path));

      await openDb(); // production re-opens lazily via provider invalidation
      expect(await nodeLabels(), ['A']);

      // "Regresar a los datos actuales": restoring the pre-restore snapshot
      // brings state 2 back.
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      await svc.restoreBackup(preRestore);
      await openDb();
      expect(await nodeLabels(), ['A', 'B']);
    },
  );

  test('restore refuses a backup whose file disappeared', () async {
    final svc = service();
    final backup = await svc.createBackup(kind: BackupKind.manual);
    await File(backup.path).delete();
    expect(() => svc.restoreBackup(backup), throwsStateError);
  });
}
