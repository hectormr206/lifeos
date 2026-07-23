// Proves the Cerebro 3D screen builds its graph from the LOCAL store via the
// payload provider. On the test host there is no WebView platform
// (WebViewPlatform.instance == null), so the screen renders its textual
// summary fallback — which is exactly the smoke-fake seam: the same payload
// that the fallback prints is what gets injected into the WebView on-device.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

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

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in tests');

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();
}

GraphNodeRecord _node(String uuid, String kind) {
  final t = DateTime.utc(2026, 6, 1);
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: 'label-$uuid',
    createdAt: t,
    updatedAt: t,
  );
}

Widget _app(LocalGraphStore store) => ProviderScope(
      overrides: [
        localGraphStoreProvider.overrideWith((ref) async => store),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Brain3dScreen(),
      ),
    );

void main() {
  testWidgets('renders the title and the local graph summary (fallback path)',
      (tester) async {
    final t = DateTime.utc(2026, 1, 1);
    final store = _FakeLocalGraphStore(
      nodes: [_node('f1', 'fact'), _node('p1', 'person')],
      edges: [
        GraphEdgeRecord(
          uuid: 'e1',
          srcUuid: 'f1',
          dstUuid: 'p1',
          relation: 'involves-person',
          createdAt: t,
          updatedAt: t,
        ),
      ],
    );

    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    expect(find.text('Cerebro 3D'), findsOneWidget);
    expect(find.text('2 nodos · 1 enlaces en el grafo local'), findsOneWidget);
  });

  testWidgets('empty local graph shows the friendly empty state', (tester) async {
    await tester.pumpWidget(_app(_FakeLocalGraphStore()));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'Aún no hay recuerdos en el grafo local. Conversa con Axi y su cerebro crecerá.'),
      findsOneWidget,
    );
  });
}
