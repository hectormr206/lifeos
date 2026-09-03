// Proves the Cerebro 3D payload builder reads the ON-DEVICE graph correctly
// through the store's read API only: merges its OWN kind list newest-first,
// caps at 500 nodes for phone performance (flagging truncation), keeps only
// edges whose BOTH endpoints survived the cap (deduped), and serializes to
// the exact JSON contract assets/brain3d/brain3d.html expects.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_payload.dart';
import 'package:lifeos/features/graph/presentation/local_graph_notifier.dart'
    show kLocalGraphKinds;

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
    {String? domain, DateTime? occurredAt, String? label, Map<String, Object?>? data}) {
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: label ?? 'label-$uuid',
    data: data ?? const <String, Object?>{},
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
    test('includes knowledge kinds and keeps only edges between included nodes', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0, domain: 'health'),
          _node('p1', 'person', t0.add(const Duration(minutes: 2))),
          _node('ev1', 'event', t0.add(const Duration(minutes: 3))),
          // Chat plumbing — excluded from the "brain of your life" view.
          _node('c1', 'conversation', t0.add(const Duration(minutes: 1))),
          // Kind the builder does not read — excluded entirely.
          _node('x1', 'unknown-kind', t0),
        ],
        edges: [
          _edge('e1', 'f1', 'p1', relation: 'involves-person'),
          // Dangling endpoint (x1 not included) — must be dropped.
          _edge('e2', 'f1', 'x1'),
          // Endpoint c1 (conversation) excluded — must be dropped too.
          _edge('e3', 'f1', 'c1'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), containsAll(['f1', 'p1', 'ev1']));
      expect(payload.nodes.map((n) => n.uuid), isNot(contains('c1')));
      expect(payload.nodes.map((n) => n.uuid), isNot(contains('x1')));
      expect(payload.truncated, isFalse);
      expect(payload.edges, hasLength(1));
      expect(payload.edges.single.uuid, 'e1');
    });

    test('excludes conversation and chat_message plumbing entirely', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0, label: 'Presión 120/80'),
          _node('c1', 'conversation', t0, label: 'Chat con Axi'),
          _node('m1', 'chat_message', t0, label: 'Hola'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), ['f1']);
    });

    test('keeps the user hub (person role=user "Yo") and connects it', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('hub', 'person', t0,
              label: 'Yo', data: const {'role': 'user'}),
          _node('f1', 'fact', t0.add(const Duration(minutes: 1)),
              label: 'Presión 120/80'),
        ],
        edges: [_edge('e1', 'hub', 'f1', relation: 'about')],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), containsAll(['hub', 'f1']));
      expect(payload.edges.single.uuid, 'e1');
    });

    test('drops trivial greeting/filler facts (low-value guard)', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('g1', 'fact', t0, label: 'hola'),
          _node('g2', 'fact', t0, label: 'gracias'),
          _node('g3', 'fact', t0, label: 'ok'),
          _node('g4', 'fact', t0, label: 'Buenos días'),
          _node('g5', 'fact', t0, label: '  Gracias!  '),
          // Real knowledge — must survive.
          _node('f1', 'fact', t0, label: 'Celia cumple años el 3 de mayo'),
          _node('f2', 'fact', t0, label: 'Presión 120/80'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), ['f1', 'f2']);
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

    // ── Generic `entity` nodes (SLICE: relations that pointed nowhere) ──────
    //
    // MemoryWriter.ensureEntity writes places, medications, orgs and things as
    // kind `entity`, and RelationExtractor points real triples at them. The 3D
    // used to load only the browser's chip kinds, so those nodes never entered
    // the payload — and because an edge survives only when BOTH endpoints did,
    // "Tere --vive_en--> Monterrey" vanished from the drawing without a word.
    test('includes entity nodes and the edges that reach them', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('f1', 'fact', t0, label: 'Tere vive en Monterrey'),
          _node('p1', 'person', t0.add(const Duration(minutes: 1)),
              label: 'Tere'),
          _node('e1', 'entity', t0.add(const Duration(minutes: 2)),
              label: 'Monterrey'),
        ],
        edges: [
          _edge('r1', 'p1', 'e1', relation: 'vive_en'),
          _edge('r2', 'f1', 'p1', relation: 'involves-person'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), containsAll(['f1', 'p1', 'e1']));
      expect(
        payload.edges.map((e) => e.uuid),
        containsAll(['r1', 'r2']),
        reason: 'the entity endpoint is in the payload, so its edge must be too',
      );
      final json = payload.toJson();
      final nodes = (json['nodes'] as List).cast<Map<String, Object?>>();
      expect(nodes.singleWhere((n) => n['id'] == 'e1')['kind'], 'entity');
    });

    test('keeps bare single-word entities (isLowValue is a fact-only rule)',
        () async {
      // An entity's whole content IS its label: "Monterrey" is one short token
      // with no data, exactly what isLowValue deletes in a fact. Screening
      // entities with it would empty the very category this slice adds.
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('e1', 'entity', t0, label: 'Monterrey'),
          _node('e2', 'entity', t0, label: 'paracetamol'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), containsAll(['e1', 'e2']));
    });

    // "Claro" es la telco, y en Mexico sale en cualquier conversacion sobre el
    // recibo del telefono. La lista de saludos existe para cazar extracciones
    // MALAS, no para borrar una marca: una entidad que el usuario no encuentra
    // en ninguna pantalla es, para el, algo que Axi no recuerda — que es justo
    // el bug que estas entidades vinieron a cerrar.
    test('una palabra que tambien es marca sobrevive como entidad', () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('c1', 'entity', t0, label: 'Claro'),
          _node('g1', 'entity', t0, label: 'hola'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), ['c1']);
    });

    test('drops greeting/empty entities so bad extractions do not litter it',
        () async {
      final store = _FakeLocalGraphStore(
        nodes: [
          _node('g1', 'entity', t0, label: 'hola'),
          _node('g2', 'entity', t0, label: '  Gracias!  '),
          _node('g3', 'entity', t0, label: '   '),
          _node('e1', 'entity', t0, label: 'Monterrey'),
        ],
      );

      final payload = await buildBrain3dPayload(store);

      expect(payload.nodes.map((n) => n.uuid), ['e1']);
    });

    test('the 3D owns its kind list, separate from the browser filter chips',
        () async {
      // Decoupled on purpose: kLocalGraphKinds is the memory browser's chip
      // taxonomy, and letting it define what the brain LOADS is what hid
      // entities in the first place.
      expect(kBrain3dKinds, contains('entity'));
      expect(kBrain3dKinds, containsAll(['fact', 'person', 'event']));
      expect(kBrain3dKinds, isNot(contains('conversation')));
      // Las dos listas COMPARTEN 'entity' — el navegador también lo muestra
      // ahora — pero siguen siendo independientes, y esta es la diferencia que
      // lo prueba: el navegador lista las conversaciones y el cerebro no.
      // Mientras esto se cumpla, ninguna de las dos define a la otra.
      expect(
        kLocalGraphKinds.map((e) => e.kind),
        contains('conversation'),
        reason: 'el navegador sí lista el registro del chat',
      );
      expect(
        kBrain3dKinds,
        isNot(contains('conversation')),
        reason: 'el cerebro muestra conocimiento, no el registro del chat',
      );
    });

    test('the cap still holds (and still flags) once entities are loaded',
        () async {
      // 6 nodes per kind across 4 kinds, capped at 10: the 10 newest win and
      // truncation is still reported. Interleaved timestamps so no single kind
      // can fill the cap on its own.
      final kinds = ['fact', 'person', 'event', 'entity'];
      final nodes = [
        for (var i = 0; i < 24; i++)
          _node('n$i', kinds[i % 4], t0.add(Duration(minutes: i)),
              label: 'nodo $i'),
      ];
      final store = _FakeLocalGraphStore(nodes: nodes, edges: [
        _edge('e-new', 'n23', 'n22'),
        _edge('e-old', 'n23', 'n0'),
      ]);

      final payload = await buildBrain3dPayload(store, maxNodes: 10);

      expect(payload.nodes, hasLength(10));
      expect(payload.truncated, isTrue);
      expect(
        payload.nodes.map((n) => n.uuid),
        [for (var i = 23; i >= 14; i--) 'n$i'],
      );
      expect(payload.edges.map((e) => e.uuid), ['e-new']);
    });

    test('empty store yields an empty, untruncated payload', () async {
      final payload = await buildBrain3dPayload(_FakeLocalGraphStore());
      expect(payload.nodes, isEmpty);
      expect(payload.edges, isEmpty);
      expect(payload.truncated, isFalse);
    });
  });
}
