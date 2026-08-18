// Stamping local writes so they can ever be synced.
//
// The Dart mirror of `axi/src/axi/sync/stamping.py`. Without it the phone's
// graph writes rows with `lamport = 0` and a NULL origin — and every query the
// engine runs is `WHERE lamport > cursor`, so an unstamped row is invisible to
// sync for ever. It is not "sync is slow"; it is "nothing exists to send".
//
// Two values go on every write:
//
//   * `origin_node` — WHICH device authored it. Used only to break ties, but
//     without it two simultaneous edits have no deterministic winner and the
//     two devices can settle on DIFFERENT rows, which is worse than either
//     choice: they stop converging and nothing reports it.
//   * `lamport` — a logical clock, not a timestamp. Wall clocks on phones jump
//     (timezones, NTP, a user setting the date), and a clock that goes backwards
//     makes a new edit lose to an old one permanently.
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const String kSyncIdentityTable = 'sync_identity';
const String kSyncPeerStateTable = 'sync_peer_state';
const String kSyncAppliedTable = 'sync_applied';
const String kSyncConflictsTable = 'sync_conflicts';

/// A peer we have never heard from. `-1` and not `0` because lamport values
/// start at 1: with `0` the very first row would fail `lamport > cursor` and
/// never ship.
const int kCursorUnsynced = -1;

const _uuid = Uuid();

/// Create the bookkeeping tables. Idempotent, and called at startup rather
/// than on first use: a table that springs into existence the moment something
/// goes wrong is a table whose absence reads as "no conflicts" and whose
/// queries fail on a perfectly healthy device.
Future<void> ensureSyncTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $kSyncIdentityTable (
      id     INTEGER PRIMARY KEY CHECK (id = 1),
      origin TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $kSyncPeerStateTable (
      peer_uuid    TEXT PRIMARY KEY,
      -- How far THIS peer has confirmed applying of OUR rows. Only their echo
      -- moves it.
      cursor       INTEGER NOT NULL DEFAULT $kCursorUnsynced,
      -- How far WE have applied of THEIR rows. This is what we echo back, and
      -- keeping it separate is what stops the two directions from being
      -- conflated into one number that is wrong for both.
      applied_high INTEGER NOT NULL DEFAULT 0,
      updated_at   REAL NOT NULL
    )
  ''');
  // The relay guarantees at-least-once delivery, never exactly-once, so
  // idempotency has to live here: the same envelope arriving twice must be a
  // no-op, not a double apply.
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $kSyncAppliedTable (
      env_id     TEXT PRIMARY KEY,
      applied_at REAL NOT NULL
    )
  ''');
  // Every revision that LOST a merge. The UNIQUE key is what stops a
  // redelivered envelope from making the user stare at the same decision twice.
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $kSyncConflictsTable (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid           TEXT NOT NULL,
      losing_lamport INTEGER NOT NULL,
      losing_origin  TEXT,
      losing_payload TEXT NOT NULL,
      resolved_at    REAL NOT NULL,
      UNIQUE(uuid, losing_lamport, losing_origin, losing_payload)
    )
  ''');
}

/// This device's identity inside the user's own device set.
///
/// Generated once and persisted. NEVER derived from the recovery phrase or any
/// hardware id: the phrase is shared by every device (so it could not tell them
/// apart) and a hardware id would follow the user across a factory reset and
/// leak into the tiebreak.
///
/// The relay is never told this value — it only ever sees a mailbox id.
Future<String> localOrigin(DatabaseExecutor db) async {
  await ensureSyncTables(db);
  final existing = await db.query(kSyncIdentityTable, where: 'id = 1');
  if (existing.isNotEmpty) return existing.first['origin']! as String;

  final origin = _uuid.v4();
  // INSERT OR IGNORE, not plain INSERT: two writes racing at first launch must
  // not crash, and whichever lands first is equally valid.
  await db.rawInsert(
    'INSERT OR IGNORE INTO $kSyncIdentityTable(id, origin) VALUES (1, ?)',
    [origin],
  );
  final settled = await db.query(kSyncIdentityTable, where: 'id = 1');
  return settled.first['origin']! as String;
}

/// The next logical clock value for a local write.
///
/// Reads the high-water mark from the graph itself rather than keeping a
/// counter in memory. Slightly more work per write, and worth it: a cached
/// counter and the table can disagree after a crash, a restore from backup, or
/// a second isolate writing — and every one of those makes new rows quietly
/// unsyncable by reusing a number the peer already has.
///
/// This also absorbs INCOMING rows: applying a peer's row at lamport 40 lifts
/// the mark, so the next local write is 41 and cannot collide with it.
Future<int> nextLamport(DatabaseExecutor db) async {
  final rows = await db.rawQuery('''
    SELECT MAX(high) AS high FROM (
      SELECT COALESCE(MAX(lamport), 0) AS high FROM nodes
      UNION ALL
      SELECT COALESCE(MAX(lamport), 0) AS high FROM edges
    )
  ''');
  final current = rows.first['high'] as int? ?? 0;
  return current + 1;
}

/// Record an envelope as applied. False when it had already been seen.
Future<bool> rememberApplied(DatabaseExecutor db, String envId) async {
  await ensureSyncTables(db);
  final changed = await db.rawInsert(
    'INSERT OR IGNORE INTO $kSyncAppliedTable(env_id, applied_at) VALUES (?, ?)',
    [envId, DateTime.now().millisecondsSinceEpoch / 1000.0],
  );
  return changed != 0;
}
