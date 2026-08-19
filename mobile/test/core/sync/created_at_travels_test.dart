// A memory keeps the day it was born, on every device.
//
// "El cerebro 3D debe verse exactamente igual ya que ambos están sincronizados."
// Right, and it did not — because the two devices did not hold the same rows.
//
// The payload never carried `created_at`, so the receiver stamped the row with
// the sender's `updated_at` instead. A memory written on Monday and edited on
// Friday was born on Monday on one device and on Friday on the other. The 3D
// view orders by creation date, so the same graph drew differently — and worse,
// the node CAP picks the newest, so the two devices could show different
// subsets of the same memories.
//
// The picture was the symptom. The wrong birthday is the defect.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/sync/data/graph_sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempRoot;
  late Database dbA;
  late Database dbB;
  late SqfliteLocalGraphStore storeA;
  late SqfliteLocalGraphStore storeB;
  late GraphSyncEngine engineA;
  late GraphSyncEngine engineB;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-born-');
    dbA = await databaseFactoryFfi.openDatabase('${tempRoot.path}/a.db',
        options: graphOpenOptions());
    dbB = await databaseFactoryFfi.openDatabase('${tempRoot.path}/b.db',
        options: graphOpenOptions());
    storeA = SqfliteLocalGraphStore(dbA);
    storeB = SqfliteLocalGraphStore(dbB);
    engineA = GraphSyncEngine(dbA);
    engineB = GraphSyncEngine(dbB);
    await engineA.ensureReady();
    await engineB.ensureReady();
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tempRoot.delete(recursive: true);
  });

  Future<void> push() async {
    final payload = await engineA.buildPayload(peerUuid: 'B');
    await engineB.applyPayload(payload, envId: 'e-${payload.hashCode}');
  }

  test('the payload carries the creation date', () async {
    await storeA.createNode(kind: 'fact', label: 'nace hoy');

    final payload = await engineA.buildPayload(peerUuid: 'B');
    final row = (payload['rows']['nodes'] as List).first as Map;

    expect(row.containsKey('created_at'), isTrue,
        reason: 'without it the receiver has to invent a birthday');
  });

  test('an edited memory keeps its ORIGINAL birthday on the other device',
      () async {
    // The case that made the two graphs differ: created long ago, edited just
    // now. Without created_at the receiver records the edit time as the birth.
    final node = await storeA.createNode(kind: 'fact', label: 'vieja');
    await dbA.update('nodes', {'created_at': 1000.0},
        where: 'uuid = ?', whereArgs: [node.uuid]);
    await storeA.upsertNode(
      (await storeA.getNodeByUuid(node.uuid))!.copyWith(label: 'editada'),
    );

    await push();

    final onA = await storeA.getNodeByUuid(node.uuid);
    final onB = await storeB.getNodeByUuid(node.uuid);
    expect(onB!.createdAt.millisecondsSinceEpoch,
        onA!.createdAt.millisecondsSinceEpoch,
        reason: 'the memory was born on a different day on each device');
  });

  test('both devices then order their memories identically', () async {
    // The user's actual requirement: same data, same picture.
    for (var i = 0; i < 5; i++) {
      final n = await storeA.createNode(kind: 'fact', label: 'm$i');
      await dbA.update('nodes', {'created_at': 1000.0 + i},
          where: 'uuid = ?', whereArgs: [n.uuid]);
    }

    await push();

    final a = [
      for (final n in await storeA.listNodesByKind('fact')) n.uuid,
    ];
    final b = [
      for (final n in await storeB.listNodesByKind('fact')) n.uuid,
    ];
    expect(b, a, reason: 'the same memories in a different order draw a '
        'different graph');
  });
}
