// Proves the ON-DEVICE graph browser (roadmap SLICE C5) reads the local store:
// the list renders nodes, the kind chips + search filter them, tapping a node
// opens its detail (data + relations), and tapping a relation navigates one hop
// to the related node's own detail. Also covers the empty state. No device DB —
// LocalGraphStore is faked in memory; localGraphStoreProvider is overridden.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/graph/presentation/local_graph_browser_screen.dart';
import 'package:lifeos/features/graph/presentation/local_graph_node_screen.dart';

/// In-memory [LocalGraphStore] over fixed node + edge lists. Only the read
/// methods the browser uses are implemented.
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
  Future<List<GraphNodeRecord>> searchNodes(String query,
      {int limit = 20, bool includeDeleted = false}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return nodes
        .where((n) => n.label.toLowerCase().contains(q))
        .take(limit)
        .toList();
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid,
      {bool includeDeleted = false}) async {
    for (final n in nodes) {
      if (n.uuid == uuid) return n;
    }
    return null;
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String nodeUuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    return edges.where((e) {
      final touches = switch (direction) {
        EdgeDirection.outgoing => e.srcUuid == nodeUuid,
        EdgeDirection.incoming => e.dstUuid == nodeUuid,
        EdgeDirection.both => e.srcUuid == nodeUuid || e.dstUuid == nodeUuid,
      };
      return touches && (relation == null || e.relation == relation);
    }).toList();
  }

  // ── Unused by the browser ────────────────────────────────────────────────
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in tests');

  @override
  Future<List<GraphNodeRecord>> neighbors(String nodeUuid,
          {EdgeDirection direction = EdgeDirection.outgoing,
          String? relation}) =>
      throw UnimplementedError();

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();
}

GraphNodeRecord _node({
  required String uuid,
  required String kind,
  required String label,
  String? domain,
  Map<String, Object?> data = const {},
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.utc(2026, 1, 1);
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: label,
    domain: domain,
    data: data,
    createdAt: now,
    updatedAt: now,
  );
}

GraphEdgeRecord _edge({
  required String uuid,
  required String src,
  required String dst,
  required String relation,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return GraphEdgeRecord(
    uuid: uuid,
    srcUuid: src,
    dstUuid: dst,
    relation: relation,
    createdAt: now,
    updatedAt: now,
  );
}

GoRouter _router() => GoRouter(
      initialLocation: '/settings/graph',
      routes: [
        GoRoute(
          path: '/settings/graph',
          builder: (context, state) => const LocalGraphBrowserScreen(),
        ),
        GoRoute(
          path: '/settings/graph/:uuid',
          builder: (context, state) =>
              LocalGraphNodeScreen(nodeUuid: state.pathParameters['uuid']!),
        ),
      ],
    );

Widget _app(LocalGraphStore store) => ProviderScope(
      overrides: [
        localGraphStoreProvider.overrideWith((ref) async => store),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    );

void main() {
  testWidgets('empty store shows the friendly empty-state message',
      (tester) async {
    await tester.pumpWidget(_app(_FakeLocalGraphStore()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Aún no hay nada en tu memoria'), findsOneWidget);
  });

  testWidgets('renders on-device nodes in the list', (tester) async {
    final store = _FakeLocalGraphStore(nodes: [
      _node(
        uuid: 'n1',
        kind: 'fact',
        label: 'Le gusta el café',
        domain: 'preferences',
        createdAt: DateTime.utc(2026, 2, 1),
      ),
      _node(uuid: 'n2', kind: 'person', label: 'García', domain: 'relationships'),
    ]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    expect(find.text('Le gusta el café'), findsOneWidget);
    expect(find.text('García'), findsOneWidget);
    // Subtitle shows the Spanish kind label + domain.
    expect(find.textContaining('Hechos'), findsWidgets);
  });

  testWidgets('search filters the list via searchNodes', (tester) async {
    final store = _FakeLocalGraphStore(nodes: [
      _node(uuid: 'n1', kind: 'fact', label: 'Le gusta el café'),
      _node(uuid: 'n2', kind: 'person', label: 'García'),
    ]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'garcía');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('García'), findsOneWidget);
    expect(find.text('Le gusta el café'), findsNothing);
  });

  testWidgets('a search with no matches shows a no-results message',
      (tester) async {
    final store = _FakeLocalGraphStore(nodes: [
      _node(uuid: 'n1', kind: 'fact', label: 'Le gusta el café'),
    ]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nadie');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.textContaining('Sin resultados'), findsOneWidget);
  });

  testWidgets('kind chip filters to a single kind', (tester) async {
    final store = _FakeLocalGraphStore(nodes: [
      _node(uuid: 'n1', kind: 'fact', label: 'Le gusta el café'),
      _node(uuid: 'n2', kind: 'person', label: 'García'),
    ]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'Personas'));
    await tester.pumpAndSettle();

    expect(find.text('García'), findsOneWidget);
    expect(find.text('Le gusta el café'), findsNothing);
  });

  testWidgets('tap node -> detail shows data + relations -> relation navigates',
      (tester) async {
    final store = _FakeLocalGraphStore(
      nodes: [
        _node(
          uuid: 'garcia',
          kind: 'person',
          label: 'García',
          domain: 'relationships',
          data: const {'role': 'amigo'},
        ),
        _node(uuid: 'hector', kind: 'person', label: 'Héctor'),
      ],
      edges: [
        _edge(uuid: 'e1', src: 'garcia', dst: 'hector', relation: 'married_to'),
      ],
    );
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('García'));
    await tester.pumpAndSettle();

    // Detail: data payload + relation rendered.
    expect(find.text('role'), findsOneWidget);
    expect(find.text('amigo'), findsOneWidget);
    expect(find.textContaining('married_to'), findsOneWidget);
    expect(find.textContaining('Héctor'), findsOneWidget);

    // Tap the relation -> navigate one hop to Héctor's own detail, where the
    // reverse (incoming) edge now points back to García.
    await tester.tap(find.textContaining('married_to'));
    await tester.pumpAndSettle();

    // App bar title is now Héctor, and its relation row points back to García.
    expect(find.widgetWithText(AppBar, 'Héctor'), findsOneWidget);
    expect(find.textContaining('García'), findsWidgets);
    expect(find.byIcon(Icons.arrow_back), findsWidgets);
  });
}
