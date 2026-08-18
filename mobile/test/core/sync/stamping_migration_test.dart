// Upgrading a device that already had the old sync tables.
//
// Shipped broken, and the device said so:
//
//   no such column: last_deposit
//   UPDATE sync_identity SET last_deposit = ? WHERE id = 1
//
// The columns were added inside `CREATE TABLE IF NOT EXISTS`, which does
// nothing at all when the table already exists. Every install that had enabled
// sync before the change kept the old shape, and every pass failed — while a
// FRESH install worked perfectly, which is exactly why the test suite was
// green: it only ever created new tables.
//
// So this suite starts from the OLD schema on purpose. A migration test that
// begins with the current schema tests nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/stamping.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openWithOldSchema() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  // Exactly the shape shipped before the change — no `last_deposit`, no
  // `applied_high`.
  await db.execute('''
    CREATE TABLE sync_identity (
      id     INTEGER PRIMARY KEY CHECK (id = 1),
      origin TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_peer_state (
      peer_uuid  TEXT PRIMARY KEY,
      cursor     INTEGER NOT NULL DEFAULT -1,
      updated_at REAL NOT NULL
    )
  ''');
  return db;
}

Future<Set<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final r in rows) r['name']! as String};
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;

  setUp(() async => db = await _openWithOldSchema());
  tearDown(() async => db.close());

  test('the missing columns are added to tables that already exist', () async {
    await ensureSyncTables(db);

    expect(await _columns(db, kSyncIdentityTable), contains('last_deposit'));
    expect(await _columns(db, kSyncPeerStateTable), contains('applied_high'));
  });

  test('upgrading keeps the device identity', () async {
    // The origin is what every stamped row already points at. Recreating the
    // table instead of altering it would hand the device a NEW identity, and
    // every row it had authored would suddenly look like a stranger's.
    await db.insert(kSyncIdentityTable, {'id': 1, 'origin': 'origen-viejo'});

    await ensureSyncTables(db);

    expect(await localOrigin(db), 'origen-viejo');
  });

  test('upgrading keeps what we knew about a peer', () async {
    await db.insert(kSyncPeerStateTable, {
      'peer_uuid': 'par-1',
      'cursor': 42,
      'updated_at': 1000.0,
    });

    await ensureSyncTables(db);

    final rows = await db.query(kSyncPeerStateTable, where: 'peer_uuid = ?',
        whereArgs: ['par-1']);
    expect(rows.single['cursor'], 42,
        reason: 'losing the cursor would resend the whole graph');
  });

  test('the write that was failing now works', () async {
    await ensureSyncTables(db);

    await rememberDeposit(db, 'abc123');

    expect(await lastDeposit(db), 'abc123');
  });

  test('running it twice does not fail', () async {
    // It runs on every pass, so a second call must be a no-op and not a
    // duplicate-column error.
    await ensureSyncTables(db);
    await ensureSyncTables(db);

    expect(await _columns(db, kSyncIdentityTable), contains('last_deposit'));
  });

  test('a fresh database gets the columns too', () async {
    final fresh = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(fresh.close);

    await ensureSyncTables(fresh);

    expect(await _columns(fresh, kSyncPeerStateTable), contains('applied_high'));
  });
}
