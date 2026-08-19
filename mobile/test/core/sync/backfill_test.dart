// Giving the memories that predate the clock a place in it.
//
// Reported: the phone shows many memories, the laptop shows two, and both say
// they are synced. They were — of everything the cursor could see.
//
// Every row written before stamping shipped has `lamport = 0`. The first pass
// sends them (0 > -1), the receiver applies them and echoes a high-water of 0,
// the sender advances its cursor to 0 — and from that moment every remaining
// lamport-0 row fails `lamport > cursor` and is excluded FOR EVER. Some data
// crosses, the rest silently never will, and both devices report success.
//
// axi has had `backfill()` since the first slice. This is the port that was
// never written.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/sync/stamping.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempRoot;
  late Database db;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-backfill-');
    db = await databaseFactoryFfi.openDatabase('${tempRoot.path}/g.db',
        options: graphOpenOptions());
  });

  tearDown(() async {
    await db.close();
    await tempRoot.delete(recursive: true);
  });

  Future<void> insertPreClockNode(String uuid, {String? origin}) =>
      db.insert('nodes', {
        'uuid': uuid,
        'kind': 'fact',
        'label': 'anterior al reloj $uuid',
        'data': '{}',
        'created_at': 1000.0,
        'updated_at': 1000.0,
        'lamport': 0,
        'origin_node': origin,
      });

  Future<List<Map<String, Object?>>> nodes() =>
      db.query('nodes', orderBy: 'uuid');

  test('rows stuck at lamport 0 are lifted above it', () async {
    for (var i = 0; i < 5; i++) {
      await insertPreClockNode('n$i');
    }

    await backfillSyncStamps(db);

    for (final row in await nodes()) {
      expect(row['lamport'] as int, greaterThan(0),
          reason: 'a lamport-0 row can never pass `lamport > cursor` again');
    }
  });

  test('every row gets a DIFFERENT clock value', () async {
    // All-equal clocks would make the whole set tie on every future merge, and
    // the tiebreak would decide by origin uuid — effectively at random.
    for (var i = 0; i < 5; i++) {
      await insertPreClockNode('n$i');
    }

    await backfillSyncStamps(db);

    final values = [for (final r in await nodes()) r['lamport'] as int];
    expect(values.toSet(), hasLength(values.length));
  });

  test('a row that arrived FROM another device keeps its author', () async {
    // Overwriting it would make this device claim authorship of everything it
    // ever received, and the deterministic tiebreak would stop meaning
    // anything.
    await insertPreClockNode('mine');
    await insertPreClockNode('theirs', origin: 'otro-dispositivo');

    await backfillSyncStamps(db);

    final rows = await nodes();
    final theirs = rows.firstWhere((r) => r['uuid'] == 'theirs');
    expect(theirs['origin_node'], 'otro-dispositivo');
    final mine = rows.firstWhere((r) => r['uuid'] == 'mine');
    expect(mine['origin_node'], isNotNull);
    expect(mine['origin_node'], isNot('otro-dispositivo'));
  });

  test('running it twice changes nothing the second time', () async {
    // It runs at every startup; a second pass must not renumber rows that are
    // already stamped, or every restart would look like a graph full of edits.
    await insertPreClockNode('n1');
    await backfillSyncStamps(db);
    final first = (await nodes()).first['lamport'];

    await backfillSyncStamps(db);

    expect((await nodes()).first['lamport'], first);
  });

  test('it does not disturb rows that already have a clock', () async {
    await db.insert('nodes', {
      'uuid': 'nuevo',
      'kind': 'fact',
      'label': 'ya sellada',
      'data': '{}',
      'created_at': 2000.0,
      'updated_at': 2000.0,
      'lamport': 42,
      'origin_node': 'yo',
    });

    await backfillSyncStamps(db);

    final row = (await nodes()).first;
    expect(row['lamport'], 42);
    expect(row['origin_node'], 'yo');
  });

  test('the next local write lands ABOVE everything backfilled', () async {
    for (var i = 0; i < 4; i++) {
      await insertPreClockNode('n$i');
    }

    await backfillSyncStamps(db);
    final next = await nextLamport(db);

    for (final row in await nodes()) {
      expect(next, greaterThan(row['lamport'] as int),
          reason: 'a new row must not collide with a backfilled one');
    }
  });

  test('edges are lifted too', () async {
    // An edge stuck at 0 is a relationship that never crosses — the picture on
    // the other device would have the nodes and none of the lines.
    await insertPreClockNode('a');
    await insertPreClockNode('b');
    await db.insert('edges', {
      'uuid': 'e1',
      'src_uuid': 'a',
      'dst_uuid': 'b',
      'relation': 'esposa',
      'data': '{}',
      'created_at': 1000.0,
      'updated_at': 1000.0,
      'lamport': 0,
    });

    await backfillSyncStamps(db);

    final edge = (await db.query('edges')).first;
    expect(edge['lamport'] as int, greaterThan(0));
    expect(edge['origin_node'], isNotNull);
  });
}
