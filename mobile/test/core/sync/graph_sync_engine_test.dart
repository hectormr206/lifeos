// The test the plan never had.
//
// Sixty tasks were marked done and every component passed its own suite while
// the feature did not work at all: `SyncScheduler` and `RelayClient` had zero
// production callers, "Sincronizar ahora" was `() {}`, and local writes left
// `lamport` at 0 with a NULL origin — so there was nothing to send even if
// something had been sending.
//
// Each piece was green in isolation. What was never asserted is the only thing
// the user actually asked for: A ROW CREATED ON ONE DEVICE APPEARS ON THE
// OTHER. That is what this file pins, against two REAL databases, plus the
// four ways it can silently go wrong:
//
//   * a redelivered envelope applying twice (the relay promises at-least-once,
//     never exactly-once);
//   * a delete losing to a stale edit and the row rising from the dead;
//   * a cursor advancing before the peer confirmed, which drops rows forever;
//   * the losing side of a conflict vanishing instead of being kept.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/sync/data/graph_sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database dbA;
  late Database dbB;
  late SqfliteLocalGraphStore storeA;
  late SqfliteLocalGraphStore storeB;
  late GraphSyncEngine engineA;
  late GraphSyncEngine engineB;

  late Directory tempRoot;

  // TWO FILES, not `inMemoryDatabasePath` twice. That path is SHARED: opening
  // it a second time hands back the same database, both "devices" become one,
  // and the headline test passes without a single row ever crossing. It gave a
  // false green here before this comment existed.
  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-sync-test-');
    dbA = await databaseFactoryFfi.openDatabase(
      '${tempRoot.path}/a.db',
      options: graphOpenOptions(),
    );
    dbB = await databaseFactoryFfi.openDatabase(
      '${tempRoot.path}/b.db',
      options: graphOpenOptions(),
    );
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

  /// One full pass in one direction, WITHOUT the relay: the transport is
  /// already covered by `relay_client_test.dart`, and mixing it in here would
  /// make a merge bug look like a network bug.
  Future<GraphApplyResult> push(
    GraphSyncEngine from,
    GraphSyncEngine to, {
    required String fromPeer,
    required String toPeer,
  }) async {
    final payload = await from.buildPayload(peerUuid: toPeer);
    final result = await to.applyPayload(payload, envId: 'env-${payload.hashCode}');
    // The echo is what lets `from` advance; without it the same rows ship for
    // ever. Mirrors what a real pass piggybacks on the next payload.
    await from.recordEcho(toPeer, result.appliedHighWater);
    return result;
  }

  group('a row created on one device appears on the other', () {
    test('a node crosses', () async {
      final created = await storeA.createNode(kind: 'fact', label: 'cita dentista');

      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      final landed = await storeB.getNodeByUuid(created.uuid);
      expect(landed, isNotNull, reason: 'THE point of the whole feature');
      expect(landed!.label, 'cita dentista');
    });

    test('local writes are stamped, or there is nothing to send', () async {
      final created = await storeA.createNode(kind: 'fact', label: 'algo');

      final stored = await storeA.getNodeByUuid(created.uuid);
      expect(stored!.lamport, greaterThan(0),
          reason: 'lamport 0 means the row is invisible to `lamport > cursor`');
      expect(stored.originNode, isNotEmpty,
          reason: 'without an origin the tiebreak cannot be resolved');
    });

    test('lamport rises with every write', () async {
      final first = await storeA.createNode(kind: 'fact', label: 'uno');
      final second = await storeA.createNode(kind: 'fact', label: 'dos');

      final a = await storeA.getNodeByUuid(first.uuid);
      final b = await storeA.getNodeByUuid(second.uuid);
      expect(b!.lamport, greaterThan(a!.lamport));
    });

    test('an edge crosses with its endpoints', () async {
      final src = await storeA.createNode(kind: 'person', label: 'Ana');
      final dst = await storeA.createNode(kind: 'place', label: 'Oficina');
      final edge = await storeA.createEdge(
        srcUuid: src.uuid,
        dstUuid: dst.uuid,
        relation: 'trabaja_en',
      );

      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      final edges = await storeB.edgesForNode(src.uuid);
      expect(edges.map((e) => e.uuid), contains(edge.uuid));
    });

    test('only what is new travels on the second pass', () async {
      await storeA.createNode(kind: 'fact', label: 'vieja');
      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      await storeA.createNode(kind: 'fact', label: 'nueva');
      final payload = await engineA.buildPayload(peerUuid: 'B');

      final labels = [
        for (final n in payload['rows']['nodes'] as List) n['label'],
      ];
      expect(labels, ['nueva'],
          reason: 'resending everything every pass would grow without bound');
    });
  });

  group('the ways it goes wrong silently', () {
    test('the same envelope applied twice changes nothing', () async {
      // The relay guarantees at-least-once delivery, never exactly-once.
      await storeA.createNode(kind: 'fact', label: 'una sola vez');
      final payload = await engineA.buildPayload(peerUuid: 'B');

      final first = await engineB.applyPayload(payload, envId: 'env-1');
      final second = await engineB.applyPayload(payload, envId: 'env-1');

      expect(first.applied, 1);
      expect(second.applied, 0, reason: 'a redelivery must be a no-op');
      final all = await storeB.listNodesByKind('fact');
      expect(all.length, 1);
    });

    test('a delete beats a stale edit, so nothing rises from the dead',
        () async {
      final node = await storeA.createNode(kind: 'fact', label: 'borrame');
      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      // B edits it; A deletes it. The delete must win regardless of clocks —
      // resurrecting something the user deleted is the one merge outcome that
      // is never acceptable.
      await storeB.upsertNode(
        (await storeB.getNodeByUuid(node.uuid))!.copyWith(label: 'editado'),
      );
      await storeA.softDeleteNode(node.uuid);

      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');
      await push(engineB, engineA, fromPeer: 'B', toPeer: 'A');

      final onA = await storeA.getNodeByUuid(node.uuid, includeDeleted: true);
      final onB = await storeB.getNodeByUuid(node.uuid, includeDeleted: true);
      expect(onA!.isDeleted, isTrue);
      expect(onB!.isDeleted, isTrue, reason: 'the delete must dominate');
    });

    test('the cursor does not advance until the peer echoes', () async {
      await storeA.createNode(kind: 'fact', label: 'sin confirmar');

      // Build a payload but never echo — a pass that died mid-flight.
      await engineA.buildPayload(peerUuid: 'B');
      final again = await engineA.buildPayload(peerUuid: 'B');

      expect((again['rows']['nodes'] as List), hasLength(1),
          reason: 'unconfirmed rows must ship again, or they are lost for ever');
    });

    test('the losing revision is kept, never discarded', () async {
      final node = await storeA.createNode(kind: 'fact', label: 'de A');
      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      // Both edit the same row. One must lose; the loser has to survive
      // somewhere the user can see it.
      await storeB.upsertNode(
        (await storeB.getNodeByUuid(node.uuid))!.copyWith(label: 'version de B'),
      );
      await storeA.upsertNode(
        (await storeA.getNodeByUuid(node.uuid))!.copyWith(label: 'version de A'),
      );

      await push(engineA, engineB, fromPeer: 'A', toPeer: 'B');

      final conflicts = await engineB.conflicts();
      expect(conflicts, isNotEmpty,
          reason: 'a merge that silently drops an edit loses user data');
    });
  });

  group('the payload is the same shape Python seals', () {
    test('it carries the schema version, origin and echo', () async {
      await storeA.createNode(kind: 'fact', label: 'x');

      final payload = await engineA.buildPayload(peerUuid: 'B');

      expect(payload['schema_version'], 1);
      expect(payload['origin_device'], isNotEmpty);
      expect(payload.containsKey('peer_cursor_echo'), isTrue);
      expect((payload['rows'] as Map).keys, containsAll(['nodes', 'edges']));
    });

    test('node rows carry exactly the columns axi sends', () async {
      await storeA.createNode(kind: 'fact', label: 'x');

      final payload = await engineA.buildPayload(peerUuid: 'B');
      final row = (payload['rows']['nodes'] as List).first as Map;

      // Mirrors `changes_for` in axi/src/axi/sync/engine.py. A column added on
      // one side and forgotten on the other is a field that silently never
      // syncs.
      expect(
        row.keys.toSet(),
        {
          'uuid', 'kind', 'label', 'data', 'lamport',
          'origin_node', 'deleted_at', 'updated_at',
        },
      );
    });
  });
}
