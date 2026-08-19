// Moving rows between devices: what to send, and what to do with what arrives.
//
// The Dart counterpart of `axi/src/axi/sync/engine.py`, and deliberately the
// same wire shape — a column added on one side and forgotten on the other is a
// field that silently never syncs, which is why `graph_sync_engine_test.dart`
// asserts the exact key set rather than trusting the two files to stay in step.
//
// The engine does NOT talk to the relay. It builds a payload and applies one,
// and `RelayClient` carries it. Keeping the merge rules away from the transport
// means a merge bug can never present itself as a network bug, and the whole of
// this file is testable against two real databases with no network at all.
import 'dart:convert';

import 'package:lifeos/core/sync/merge.dart';
import 'package:lifeos/core/sync/stamping.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// Bounded so one pass cannot try to seal a whole graph into a single envelope
/// and hit the relay's 1 MiB ceiling. The cursor makes the truncation safe:
/// whatever does not fit is simply included next pass, because nothing advances
/// until the peer echoes.
const int kSyncRowLimit = 500;

/// What one apply pass did. Returned rather than logged so a caller can show
/// the user something true instead of an unconditional "listo".
class GraphApplyResult {
  const GraphApplyResult({
    required this.applied,
    required this.rejected,
    required this.conflicts,
    required this.appliedHighWater,
  });

  final int applied;
  final int rejected;
  final int conflicts;

  /// The highest lamport actually applied — what the sender needs echoed back
  /// before it may advance its cursor.
  final int appliedHighWater;

  bool get changedAnything => applied > 0;
}

/// Another device in the user's set, as this one knows it.
class SyncPeer {
  const SyncPeer({
    required this.uuid,
    required this.cursor,
    required this.appliedHigh,
    required this.lastSeen,
  });

  final String uuid;

  /// How far this peer confirmed applying of OUR rows.
  final int cursor;

  /// How far WE have applied of THEIRS.
  final int appliedHigh;

  final DateTime lastSeen;

  /// A short, stable label. The full uuid means nothing to a person and takes
  /// the whole width of a phone.
  String get shortId => uuid.length <= 6 ? uuid : uuid.substring(0, 6);
}

class GraphSyncEngine {
  GraphSyncEngine(this._db);

  final DatabaseExecutor _db;

  /// Tables, and the one-time lift of everything written before the clock.
  ///
  /// The backfill runs HERE rather than at first use: a row still at lamport 0
  /// when a pass starts is a row that pass will exclude for ever once the
  /// cursor moves past 0 — which is how one device ended up with a fraction of
  /// the other's memories while both reported a healthy sync.
  Future<void> ensureReady() async {
    await ensureSyncTables(_db);
    await backfillSyncStamps(_db);
  }

  /// How far this peer has confirmed. Unknown peers start at [kCursorUnsynced].
  Future<int> peerCursor(String peerUuid) async {
    await ensureSyncTables(_db);
    final rows = await _db.query(
      kSyncPeerStateTable,
      where: 'peer_uuid = ?',
      whereArgs: [peerUuid],
    );
    if (rows.isEmpty) return kCursorUnsynced;
    return rows.first['cursor'] as int? ?? kCursorUnsynced;
  }

  /// Advance a peer's cursor after IT confirmed what it applied.
  ///
  /// Never called from our own send path. Advancing on send would drop every
  /// row of a pass that died in flight — the rows would be marked delivered and
  /// never offered again, and neither device would report anything wrong.
  Future<void> recordEcho(String peerUuid, int appliedLamport) async {
    await ensureSyncTables(_db);
    final current = await peerCursor(peerUuid);
    // Monotonic: a late or duplicated echo carrying an older value must not
    // rewind the cursor and cause a storm of re-sends.
    final next = appliedLamport > current ? appliedLamport : current;
    await _upsertPeer(peerUuid, {'cursor': next});
  }

  /// How far we have applied of [peerUuid]'s rows — the number we echo back so
  /// THEY may advance their cursor.
  Future<int> appliedHigh(String peerUuid) async {
    await ensureSyncTables(_db);
    final rows = await _db.query(
      kSyncPeerStateTable,
      where: 'peer_uuid = ?',
      whereArgs: [peerUuid],
    );
    if (rows.isEmpty) return 0;
    return rows.first['applied_high'] as int? ?? 0;
  }

  Future<void> recordApplied(String peerUuid, int high) async {
    await ensureSyncTables(_db);
    final current = await appliedHigh(peerUuid);
    if (high <= current) return;
    await _upsertPeer(peerUuid, {'applied_high': high});
  }

  /// Update some columns of a peer row, creating it with sane defaults first.
  ///
  /// A plain `insert(replace)` would blank whichever of the two counters the
  /// caller did not mention, and each direction would silently reset the other.
  Future<void> _upsertPeer(String peerUuid, Map<String, Object?> values) async {
    await _db.rawInsert(
      'INSERT OR IGNORE INTO $kSyncPeerStateTable'
      '(peer_uuid, cursor, applied_high, updated_at) VALUES (?, ?, 0, ?)',
      [peerUuid, kCursorUnsynced, DateTime.now().millisecondsSinceEpoch / 1000.0],
    );
    await _db.update(
      kSyncPeerStateTable,
      {...values, 'updated_at': DateTime.now().millisecondsSinceEpoch / 1000.0},
      where: 'peer_uuid = ?',
      whereArgs: [peerUuid],
    );
  }

  /// Everything this peer has not confirmed, oldest first.
  Future<Map<String, dynamic>> buildPayload({
    required String peerUuid,
    int limit = kSyncRowLimit,
  }) async {
    await ensureSyncTables(_db);
    final cursor = await peerCursor(peerUuid);
    final origin = await localOrigin(_db);

    final nodes = await _db.rawQuery(
      'SELECT uuid, kind, label, data, lamport, origin_node, deleted_at,'
      ' updated_at FROM nodes WHERE lamport > ? ORDER BY lamport ASC LIMIT ?',
      [cursor, limit],
    );
    final edges = await _db.rawQuery(
      'SELECT uuid, src_uuid, dst_uuid, relation, data, lamport, origin_node,'
      ' deleted_at, updated_at FROM edges WHERE lamport > ? ORDER BY lamport ASC'
      ' LIMIT ?',
      [cursor, limit],
    );

    return <String, dynamic>{
      'schema_version': 1,
      'origin_device': origin,
      // This device telling the OTHER one how far it has applied — the same
      // mechanism in reverse. Piggybacked so a device that only ever receives
      // still advances its peer's cursor, with no extra round trip and nothing
      // extra for the relay to see.
      'peer_cursor_echo': await appliedHigh(peerUuid),
      'rows': <String, dynamic>{
        'nodes': [for (final r in nodes) Map<String, Object?>.from(r)],
        'edges': [for (final r in edges) Map<String, Object?>.from(r)],
      },
    };
  }

  /// Apply a peer's payload.
  ///
  /// [envId] makes this idempotent: the relay guarantees at-least-once
  /// delivery, so the same envelope WILL arrive twice and applying it twice
  /// must change nothing.
  Future<GraphApplyResult> applyPayload(
    Map<String, dynamic> payload, {
    required String envId,
  }) async {
    await ensureSyncTables(_db);
    if (!await rememberApplied(_db, envId)) {
      return const GraphApplyResult(
        applied: 0,
        rejected: 0,
        conflicts: 0,
        appliedHighWater: 0,
      );
    }

    final rows = (payload['rows'] as Map).cast<String, dynamic>();
    var applied = 0;
    var rejected = 0;
    var conflicts = 0;
    var high = 0;

    for (final entry in [
      ('nodes', (rows['nodes'] as List?) ?? const []),
      ('edges', (rows['edges'] as List?) ?? const []),
    ]) {
      final table = entry.$1;
      for (final raw in entry.$2) {
        final row = Map<String, Object?>.from(raw as Map);
        final outcome = await _applyRow(table, row);
        switch (outcome.$1) {
          case MergeOutcome.inserted:
          case MergeOutcome.updated:
            applied++;
            final lamport = (row['lamport'] as int?) ?? 0;
            if (lamport > high) high = lamport;
          case MergeOutcome.rejected:
            rejected++;
        }
        if (outcome.$2) conflicts++;
      }
    }

    // Remembered per sender so the NEXT payload we build echoes it back. The
    // sender cannot advance its cursor until it hears this number.
    final sender = payload['origin_device'] as String?;
    if (sender != null && sender.isNotEmpty && high > 0) {
      await recordApplied(sender, high);
    }

    return GraphApplyResult(
      applied: applied,
      rejected: rejected,
      conflicts: conflicts,
      appliedHighWater: high,
    );
  }

  /// Returns the outcome and whether it was a genuine two-device disagreement.
  Future<(MergeOutcome, bool)> _applyRow(
    String table,
    Map<String, Object?> row,
  ) async {
    final uuid = row['uuid'] as String;
    final existing = await _db.query(
      table,
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );

    final incoming = MergeRevision(
      lamport: (row['lamport'] as int?) ?? 0,
      originNode: (row['origin_node'] as String?) ?? '',
      deleted: row['deleted_at'] != null,
    );
    final local = existing.isEmpty
        ? null
        : MergeRevision(
            lamport: (existing.first['lamport'] as int?) ?? 0,
            originNode: (existing.first['origin_node'] as String?) ?? '',
            deleted: existing.first['deleted_at'] != null,
          );

    final outcome = decideMerge(local: local, incoming: incoming);
    final disagreement = isConflict(local: local, incoming: incoming);

    // The LOSING revision is preserved before anything is overwritten. A merge
    // that silently drops an edit loses user data, and the user is never told
    // which edit vanished or when.
    if (disagreement) {
      final losing = outcome == MergeOutcome.rejected ? row : existing.first;
      await _db.rawInsert(
        'INSERT OR IGNORE INTO $kSyncConflictsTable'
        '(uuid, losing_lamport, losing_origin, losing_payload, resolved_at)'
        ' VALUES (?, ?, ?, ?, ?)',
        [
          uuid,
          (losing['lamport'] as int?) ?? 0,
          losing['origin_node'] as String?,
          jsonEncode(losing.map((k, v) => MapEntry(k, v is DateTime ? v.toIso8601String() : v))),
          DateTime.now().millisecondsSinceEpoch / 1000.0,
        ],
      );
    }

    switch (outcome) {
      case MergeOutcome.inserted:
        await _db.insert(
          table,
          _insertColumns(table, row),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      case MergeOutcome.updated:
        // Only the synced columns. Writing the raw row would blank local-only
        // fields the payload does not carry (`created_at`, `domain`,
        // `occurred_at`), quietly destroying data the peer never disputed.
        await _db.update(
          table,
          _updateColumns(row),
          where: 'uuid = ?',
          whereArgs: [uuid],
        );
      case MergeOutcome.rejected:
        break;
    }

    return (outcome, disagreement && outcome != MergeOutcome.inserted);
  }

  /// Columns for a row this device has never seen.
  ///
  /// `created_at` is NOT NULL and the payload does not carry it — the wire
  /// shape is fixed by `changes_for` in axi and must not drift — so it takes
  /// `updated_at`, exactly as `apply_node` does on the Python side. Falling
  /// back to "now" instead would make every synced row look freshly created on
  /// whichever device happened to receive it.
  Map<String, Object?> _insertColumns(String table, Map<String, Object?> row) {
    final updatedAt =
        row['updated_at'] ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
    final common = <String, Object?>{
      'uuid': row['uuid'],
      'data': row['data'] ?? '{}',
      'created_at': updatedAt,
      'updated_at': updatedAt,
      'lamport': row['lamport'] ?? 0,
      'origin_node': row['origin_node'],
      'deleted_at': row['deleted_at'],
    };
    if (table == 'nodes') {
      return {
        ...common,
        'kind': row['kind'] ?? 'fact',
        'label': row['label'] ?? '',
      };
    }
    return {
      ...common,
      'src_uuid': row['src_uuid'],
      'dst_uuid': row['dst_uuid'],
      'relation': row['relation'] ?? '',
    };
  }

  /// Columns an accepted revision is allowed to overwrite.
  Map<String, Object?> _updateColumns(Map<String, Object?> row) => {
        for (final k in const [
          'kind', 'label', 'data', 'src_uuid', 'dst_uuid', 'relation',
          'updated_at', 'lamport', 'origin_node', 'deleted_at',
        ])
          if (row.containsKey(k)) k: row[k],
      };

  /// Note that a device exists, before anything has been exchanged with it.
  ///
  /// Learned from the announce board. Kept separate from the cursors so that
  /// discovering a device never rewinds what we already knew about it.
  Future<void> rememberPeer(String peerUuid) async {
    if (peerUuid.isEmpty || peerUuid == 'announce') return;
    await _upsertPeer(peerUuid, const {});
  }

  /// Every peer this device knows of, most recent first.
  ///
  /// Read from the same table the pass writes, so the screen cannot show a
  /// paired device that sync does not actually know about.
  Future<List<SyncPeer>> peers() async {
    await ensureSyncTables(_db);
    final rows = await _db.query(kSyncPeerStateTable, orderBy: 'updated_at DESC');
    return [
      for (final r in rows)
        if ((r['peer_uuid'] as String?) != null &&
            (r['peer_uuid'] as String) != 'announce')
          SyncPeer(
            uuid: r['peer_uuid']! as String,
            cursor: (r['cursor'] as int?) ?? kCursorUnsynced,
            appliedHigh: (r['applied_high'] as int?) ?? 0,
            lastSeen: DateTime.fromMillisecondsSinceEpoch(
              (((r['updated_at'] as num?) ?? 0) * 1000).round(),
            ),
          ),
    ];
  }

  /// Revisions that lost a merge, newest first.
  Future<List<Map<String, Object?>>> conflicts({int limit = 100}) async {
    await ensureSyncTables(_db);
    return _db.query(
      kSyncConflictsTable,
      orderBy: 'resolved_at DESC',
      limit: limit,
    );
  }
}
