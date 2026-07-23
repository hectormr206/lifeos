import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Unit tests for the on-device graph store (roadmap SLICE A2).
///
/// SQLCipher caveat: these run on the host VM against a REAL in-memory sqlite
/// via `sqflite_common_ffi` (dart:ffi) — NOT the encrypted SQLCipher backend,
/// which needs the native encrypted lib that only ships on a device/emulator.
/// The store's SQL is identical on both backends (SQLCipher is standard sqlite
/// plus transparent page encryption), so every query/traversal/tombstone rule
/// below is exercised exactly as it runs on-device. The keyed-open encryption
/// path itself is covered by `local_graph_database.dart` + `graph_key_store`
/// and validated on a real device, not here.
void main() {
  late Database db;
  late SqfliteLocalGraphStore store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
  });

  tearDown(() async => db.close());

  group('node upsert + read', () {
    test('createNode persists and reads back by uuid and localId', () async {
      final node = await store.createNode(
        kind: 'person',
        label: 'Héctor',
        data: {'role': 'user'},
        domain: 'home',
      );

      expect(node.localId, isNotNull);
      expect(node.uuid, isNotEmpty);

      final byUuid = await store.getNodeByUuid(node.uuid);
      expect(byUuid, isNotNull);
      expect(byUuid!.label, 'Héctor');
      expect(byUuid.kind, 'person');
      expect(byUuid.domain, 'home');
      expect(byUuid.data['role'], 'user');

      final byLocalId = await store.getNodeByLocalId(node.localId!);
      expect(byLocalId!.uuid, node.uuid);
    });

    test('upsertNode inserts then updates the same uuid in place', () async {
      final created = await store.createNode(kind: 'fact', label: 'first');
      final updated = created.copyWith(label: 'second', data: {'v': 2});

      await store.upsertNode(updated);

      final read = await store.getNodeByUuid(created.uuid);
      expect(read!.label, 'second');
      expect(read.data['v'], 2);

      // Still a single row for that uuid.
      final all = await store.listNodesByKind('fact');
      expect(all.where((n) => n.uuid == created.uuid).length, 1);
    });

    test('unknown uuid reads as null', () async {
      expect(await store.getNodeByUuid('does-not-exist'), isNull);
    });
  });

  group('edge create + traverse', () {
    late GraphNodeRecord a;
    late GraphNodeRecord b;
    late GraphNodeRecord c;

    setUp(() async {
      a = await store.createNode(kind: 'person', label: 'A');
      b = await store.createNode(kind: 'event', label: 'B');
      c = await store.createNode(kind: 'event', label: 'C');
    });

    test('createEdge links two nodes by uuid', () async {
      final edge = await store.createEdge(
        srcUuid: a.uuid,
        dstUuid: b.uuid,
        relation: 'mentioned_in',
        data: {'weight': 1},
      );
      expect(edge.localId, isNotNull);
      expect(edge.srcUuid, a.uuid);
      expect(edge.dstUuid, b.uuid);
      expect(edge.data['weight'], 1);
    });

    test('edgesForNode filters by direction', () async {
      await store.createEdge(srcUuid: a.uuid, dstUuid: b.uuid, relation: 'r1');
      await store.createEdge(srcUuid: c.uuid, dstUuid: a.uuid, relation: 'r2');

      final out = await store.edgesForNode(a.uuid, direction: EdgeDirection.outgoing);
      expect(out.map((e) => e.dstUuid), [b.uuid]);

      final inc = await store.edgesForNode(a.uuid, direction: EdgeDirection.incoming);
      expect(inc.map((e) => e.srcUuid), [c.uuid]);

      final both = await store.edgesForNode(a.uuid, direction: EdgeDirection.both);
      expect(both.length, 2);
    });

    test('edgesForNode filters by relation', () async {
      await store.createEdge(srcUuid: a.uuid, dstUuid: b.uuid, relation: 'caused_by');
      await store.createEdge(srcUuid: a.uuid, dstUuid: c.uuid, relation: 'belongs_to');

      final only = await store.edgesForNode(a.uuid, relation: 'caused_by');
      expect(only.length, 1);
      expect(only.single.dstUuid, b.uuid);
    });

    test('neighbors resolves connected nodes one hop out', () async {
      await store.createEdge(srcUuid: a.uuid, dstUuid: b.uuid, relation: 'r');
      await store.createEdge(srcUuid: a.uuid, dstUuid: c.uuid, relation: 'r');

      final out = await store.neighbors(a.uuid, direction: EdgeDirection.outgoing);
      expect(out.map((n) => n.uuid).toSet(), {b.uuid, c.uuid});

      final incFromB = await store.neighbors(b.uuid, direction: EdgeDirection.incoming);
      expect(incFromB.single.uuid, a.uuid);
    });
  });

  group('soft-delete / tombstone', () {
    test('softDeleteNode hides the node and tombstones incident edges', () async {
      final a = await store.createNode(kind: 'person', label: 'A');
      final b = await store.createNode(kind: 'event', label: 'B');
      final edge = await store.createEdge(srcUuid: a.uuid, dstUuid: b.uuid, relation: 'r');

      final ok = await store.softDeleteNode(a.uuid);
      expect(ok, isTrue);

      // Hidden from normal reads...
      expect(await store.getNodeByUuid(a.uuid), isNull);
      expect(await store.edgesForNode(a.uuid), isEmpty);

      // ...but present + tombstoned when explicitly included (sync needs this).
      final raw = await store.getNodeByUuid(a.uuid, includeDeleted: true);
      expect(raw, isNotNull);
      expect(raw!.isDeleted, isTrue);
      expect(raw.deletedAt, isNotNull);
      expect(raw.lamport, 1);

      final rawEdges = await store.edgesForNode(a.uuid, includeDeleted: true);
      expect(rawEdges.single.uuid, edge.uuid);
      expect(rawEdges.single.isDeleted, isTrue);
    });

    test('softDeleteNode on an already-deleted / missing node returns false', () async {
      final a = await store.createNode(kind: 'person', label: 'A');
      expect(await store.softDeleteNode(a.uuid), isTrue);
      expect(await store.softDeleteNode(a.uuid), isFalse);
      expect(await store.softDeleteNode('missing'), isFalse);
    });

    test('softDeleteEdge tombstones a single edge only', () async {
      final a = await store.createNode(kind: 'person', label: 'A');
      final b = await store.createNode(kind: 'event', label: 'B');
      final edge = await store.createEdge(srcUuid: a.uuid, dstUuid: b.uuid, relation: 'r');

      expect(await store.softDeleteEdge(edge.uuid), isTrue);
      expect(await store.edgesForNode(a.uuid), isEmpty);
      // Both endpoint nodes stay live.
      expect(await store.getNodeByUuid(a.uuid), isNotNull);
      expect(await store.getNodeByUuid(b.uuid), isNotNull);
    });
  });

  group('uuid uniqueness', () {
    test('every created node gets a distinct uuid', () async {
      final uuids = <String>{};
      for (var i = 0; i < 50; i++) {
        final n = await store.createNode(kind: 'fact', label: 'n$i');
        expect(uuids.add(n.uuid), isTrue, reason: 'duplicate uuid ${n.uuid}');
      }
      expect(uuids.length, 50);
    });

    test('inserting a duplicate uuid violates the UNIQUE constraint', () async {
      final n = await store.createNode(kind: 'fact', label: 'x');
      final clash = GraphNodeRecord(
        uuid: n.uuid,
        kind: 'fact',
        label: 'clash',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      // Raw insert (no replace) must throw on the UNIQUE(uuid) index.
      expect(
        () => db.insert(kNodesTable, clash.toColumns()),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('list by kind', () {
    test('returns only the requested kind, newest first, excluding tombstones', () async {
      final clock = _StepClock();
      final s = SqfliteLocalGraphStore(db, clock: clock.now);

      final oldFact = await s.createNode(kind: 'fact', label: 'old');
      await s.createNode(kind: 'person', label: 'p');
      final newFact = await s.createNode(kind: 'fact', label: 'new');
      final doomed = await s.createNode(kind: 'fact', label: 'doomed');
      await s.softDeleteNode(doomed.uuid);

      final facts = await s.listNodesByKind('fact');
      expect(facts.map((n) => n.label), ['new', 'old']);
      expect(facts.map((n) => n.uuid), [newFact.uuid, oldFact.uuid]);
    });

    test('respects limit', () async {
      for (var i = 0; i < 5; i++) {
        await store.createNode(kind: 'fact', label: 'n$i');
      }
      final limited = await store.listNodesByKind('fact', limit: 2);
      expect(limited.length, 2);
    });
  });

  group('text query', () {
    test('matches label and data substrings, hides tombstones', () async {
      await store.createNode(kind: 'fact', label: 'Aspirin dosage', data: {'note': 'take 100mg'});
      await store.createNode(kind: 'fact', label: 'unrelated', data: {'note': 'about aspirin too'});
      final deleted = await store.createNode(kind: 'fact', label: 'aspirin old');
      await store.softDeleteNode(deleted.uuid);

      final hits = await store.searchNodes('aspirin');
      expect(hits.length, 2);
      expect(hits.every((n) => !n.isDeleted), isTrue);
    });

    test('blank query returns empty', () async {
      await store.createNode(kind: 'fact', label: 'x');
      expect(await store.searchNodes('   '), isEmpty);
    });

    test('wildcard characters are matched literally', () async {
      await store.createNode(kind: 'fact', label: '50% off');
      await store.createNode(kind: 'fact', label: 'no discount');
      final hits = await store.searchNodes('50%');
      expect(hits.single.label, '50% off');
    });
  });
}

/// Monotonic clock so `created_at DESC` ordering is deterministic in tests
/// that would otherwise share the same wall-clock millisecond.
class _StepClock {
  DateTime _t = DateTime.utc(2026, 1, 1);
  DateTime now() {
    _t = _t.add(const Duration(seconds: 1));
    return _t;
  }
}
