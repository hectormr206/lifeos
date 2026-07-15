// Proves the search -> results -> detail flow: GraphBrowserScreen renders
// search results, tapping one pushes GraphNodeScreen at /graph/:id (facts,
// relations, provenance), and tapping a relation navigates to the related
// node's own detail (relation-tap navigation). Also covers the empty-search
// and no-results states. No live engine — repository faked. Real GoRouter
// (mirrors home_screen_test.dart's push-navigation pattern).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/graph/data/graph_repository.dart';
import 'package:lifeos/features/graph/domain/graph_neighborhood.dart';
import 'package:lifeos/features/graph/domain/graph_node.dart';
import 'package:lifeos/features/graph/domain/graph_node_detail.dart';
import 'package:lifeos/features/graph/presentation/graph_browser_screen.dart';
import 'package:lifeos/features/graph/presentation/graph_node_screen.dart';
import 'package:lifeos/features/graph/presentation/graph_search_notifier.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeGraphRepository implements GraphRepository {
  _FakeGraphRepository({this.searchResults = const {}, this.nodes = const {}});

  final Map<String, List<GraphNode>> searchResults;
  final Map<int, GraphNodeDetail> nodes;

  @override
  Future<List<GraphNode>> search(String query, {int limit = 20}) async => searchResults[query] ?? const [];

  @override
  Future<GraphNodeDetail> node(int id) async {
    final detail = nodes[id];
    if (detail == null) throw GraphException('nodo no encontrado');
    return detail;
  }

  @override
  Future<GraphNeighborhood> neighborhood(int id) => throw UnimplementedError();
}

GoRouter _router() => GoRouter(
      routes: [
        GoRoute(path: '/graph', builder: (context, state) => const GraphBrowserScreen()),
        GoRoute(
          path: '/graph/:id',
          builder: (context, state) => GraphNodeScreen(nodeId: int.parse(state.pathParameters['id']!)),
        ),
      ],
      initialLocation: '/graph',
    );

void main() {
  final garciaDetail = GraphNodeDetail(
    node: const GraphNodeInfo(id: 42, kind: 'person', label: 'García', domain: 'relationships'),
    facts: const [GraphFact(id: 100, label: 'Le gusta el café')],
    relations: const [
      GraphRelation(edgeId: 5, otherId: 9, otherLabel: 'Héctor', otherKind: 'person', kind: 'married_to', direction: 'out'),
    ],
    conversations: const [GraphProvenance(id: 1, userTextSnippet: 'hablé con García ayer')],
  );
  final hectorDetail = GraphNodeDetail(
    node: const GraphNodeInfo(id: 9, kind: 'person', label: 'Héctor', domain: 'relationships'),
    facts: const [],
    relations: const [],
    conversations: const [],
  );

  testWidgets('shows a hint before searching', (tester) async {
    final repo = _FakeGraphRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [graphRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();

    expect(find.text('Escribe algo para buscar en el cerebro.'), findsOneWidget);
  });

  testWidgets('submitting a query with no matches shows "Sin resultados."', (tester) async {
    final repo = _FakeGraphRepository(searchResults: const {'nadie': []});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [graphRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'nadie');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();

    expect(find.text('Sin resultados.'), findsOneWidget);
  });

  testWidgets('search -> results -> detail -> relation-tap navigation', (tester) async {
    final repo = _FakeGraphRepository(
      searchResults: {
        'garcia': [const GraphNode(id: 42, label: 'García', kind: 'person', domain: 'relationships')],
      },
      nodes: {42: garciaDetail, 9: hectorDetail},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [graphRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'garcia');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();

    expect(find.text('García'), findsOneWidget);
    await tester.tap(find.text('García'));
    await tester.pumpAndSettle();

    // Detail screen: facts, relations, provenance.
    expect(find.text('Le gusta el café'), findsOneWidget);
    expect(find.textContaining('married_to'), findsOneWidget);
    expect(find.text('hablé con García ayer'), findsOneWidget);

    // Tap the relation -> navigates to node 9's own detail.
    await tester.tap(find.textContaining('married_to'));
    await tester.pumpAndSettle();

    expect(find.text('Sin relaciones.'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache (M3 slice 1)', (tester) async {
    final repo = _FakeGraphRepository();
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          graphRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
