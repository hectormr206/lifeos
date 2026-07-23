// Proves the Cerebro 3D payload builder reads the ON-DEVICE graph correctly
// through the store's read API only: merges the local kinds newest-first,
// caps at 500 nodes for phone performance (flagging truncation), keeps only
// edges whose BOTH endpoints survived the cap (deduped), and serializes to
// the exact JSON contract assets/brain3d/brain3d.html expects.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_payload.dart';

/// In-memory read-only [LocalGraphStore] over fixed node + edge lists —
/// same shape as the local browser test's fake.
class _FakeLocalGraphStore implements LocalGraphStore {
  _FakeLocalGraphStore({this.nodes = const [], this.edges = const []});

  final List<GraphNodeRecord> nodes;
  final List<GraphEdgeRecord> edges;

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
      {int? limit, bool includeDeleted = false}) async {
    final matches = nodes.where((n) => n.kind == kind).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return limit == null ? matches : matches.take(limit).toList();
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String nodeUuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    return edges
        .where((e) => e.srcUuid == nodeUuid || e.dstUuid == nodeUuid)
        .toList();
  }

  // ── Unused by the payload builder ──────────────────────────────────────
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in tests');

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();
}

GraphNodeRecord _node(String uuid, String kind, DateTime createdAt,
    {String? domain, DateTime? occurredAt}) {
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: 'label-$uuid',
    domain: domain,
    occurredAt: occurredAt,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

GraphEdgeRecord _edge(String uuid, String src, String dst,
    {String relation = 'mentioned_in'}) {
  final t = DateTime.utc(2026, 1, 1);
  return GraphEdgeRecord(
    uuid: uuid,
    srcUuid: src,
    dstUuid: dst,
    relation: relation,
    createdAt: t,
    updatedAt: t,
  );
}

void main() {
  final t0 = DateTime.utc(2026, 6, 1, 12);

  group('buildBrain3dPayload', () {
    test('merges local kinds and keeps only edges between included nodes', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0, domain: 'health'),
          _node('c1', 'conversation', t0.add(const Duration(minutes: 1))),
          _node('p1', 'person', t0.add(const Duration(minutes: 2))),
          // Kind the builder does not read — excluded entirely.
          _node('x1', 'unknown-kind', t0),
        ],
        edges: [
          _edge('e1', 'f1', 'p1', relation: 'involves-person'),
          // Dangling endpoint (x1 not included) — must be dropped.
          _edge('e2', 'f1', 'x1'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), containsAll(['f1', 'c1', 'p1']));
      expect(payload.nodes.map((n) => n.uuid), isNot(contains('x1')));
      expect(payload.truncated, isFalse);
      expect(payload.edges, hasLength(1));
      expect(payload.edges.single.uuid, 'e1');
    });

    test('edges touching two included nodes are not duplicated', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0),
          _node('p1', 'person', t0),
        ],
        // Both endpoints included -> edgesForNode returns e1 for f1 AND p1.
        edges: [_edge('e1', 'f1', 'p1')],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.edges, hasLength(1));
    });

    test('caps at maxNodes keeping the MOST RECENT and flags truncation', () async {
      // 30 facts; cap at 10 -> the 10 newest must win.
      final nodes = [
        for (var i = 0; i < 30; i++)
          _node('f$i', 'fact', t0.add(Duration(minutes: i))),
      ];
      final store = _FakeLocalGraphStore(nodes: nodes, edges: [
        // newest <-> oldest: must be dropped (oldest falls out of the cap).
        _edge('e-old', 'f29', 'f0'),
        // newest <-> second-newest: both survive.
        _edge('e-new', 'f29', 'f28'),
      ]);

      final payload = await buildBrain3dPayload(store, maxNodes: 10);

      expect(payload.nodes, hasLength(10));
      expect(payload.truncated, isTrue);
      expect(
        payload.nodes.map((n) => n.uuid),
        [for (var i = 29; i >= 20; i--) 'f$i'],
      );
      expect(payload.edges.map((e) => e.uuid), ['e-new']);
    });

    test('default cap is 500', () {
      expect(kBrain3dMaxNodes, 500);
    });

    test('toJson matches the brain3d.html axiLoadGraph contract', () async {
      final occurred = DateTime.utc(2026, 5, 20, 8, 30);
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0, domain: 'finance', occurredAt: occurred),
          _node('p1', 'person', t0),
        ],
        edges: [_edge('e1', 'f1', 'p1', relation: 'involves-person')],
      );

      final json = (await buildBrain3dPayload(store)).toJson();

      final nodes = (json['nodes'] as List).cast<Map<String, Object?>>();
      final f1 = nodes.singleWhere((n) => n['id'] == 'f1');
      expect(f1['label'], 'label-f1');
      expect(f1['kind'], 'fact');
      expect(f1['domain'], 'finance');
      expect(f1['created_at'], t0.millisecondsSinceEpoch ~/ 1000);
      expect(f1['occurred_at'], occurred.millisecondsSinceEpoch ~/ 1000);

      final p1 = nodes.singleWhere((n) => n['id'] == 'p1');
      expect(p1['occurred_at'], isNull);

      final edges = (json['edges'] as List).cast<Map<String, Object?>>();
      expect(edges.single, {
        'source': 'f1',
        'target': 'p1',
        'kind': 'involves-person',
      });
      expect(json['truncated'], isFalse);
    });

    test('empty store yields an empty, untruncated payload', () async {
      final payload = await buildBrain3dPayload(_FakeLocalGraphStore());
      expect(payload.nodes, isEmpty);
      expect(payload.edges, isEmpty);
      expect(payload.truncated, isFalse);
    });
  });
}
