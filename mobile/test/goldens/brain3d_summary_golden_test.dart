// GOLDEN: the Cerebro 3D screen's NON-WebView textual summary.
//
// The 3D graph itself is a WebView payload and CANNOT be goldened on the test
// host (WebViewPlatform.instance == null). The screen deliberately renders a
// textual summary fallback in that case — that fallback IS what this golden
// captures (the actual 3D render is skipped; see the harness report). Store is a
// hand-rolled fake so there is no sqflite/native dependency.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'support/golden_harness.dart';

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
          bool includeDeleted = false}) async =>
      edges
          .where((e) => e.srcUuid == nodeUuid || e.dstUuid == nodeUuid)
          .toList();

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in goldens');
}

GraphNodeRecord _node(String uuid, String kind, String label) {
  final t = DateTime.utc(2026, 6, 1);
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: label,
    createdAt: t,
    updatedAt: t,
  );
}

GraphEdgeRecord _edge(String uuid, String src, String dst, String rel) {
  final t = DateTime.utc(2026, 6, 1);
  return GraphEdgeRecord(
    uuid: uuid,
    srcUuid: src,
    dstUuid: dst,
    relation: rel,
    createdAt: t,
    updatedAt: t,
  );
}

void main() {
  testWidgets('golden: Cerebro 3D — local graph summary (WebView SKIPPED)',
      (tester) async {
    useGoldenSurface(tester);

    final store = _FakeLocalGraphStore(
      nodes: [
        _node('hub', 'person', 'Yo'),
        _node('celia', 'person', 'Celia'),
        _node('f1', 'fact', 'Presión 122/77, pulso 55'),
        _node('f2', 'fact', 'Corrió 5 km en la mañana'),
        _node('f3', 'fact', 'Rezó el rosario'),
        _node('rosario', 'entity', 'rosario'),
      ],
      edges: [
        _edge('e1', 'hub', 'f1', 'about'),
        _edge('e2', 'hub', 'f2', 'about'),
        _edge('e3', 'hub', 'f3', 'about'),
        _edge('e4', 'hub', 'celia', 'esposa'),
        _edge('e5', 'hub', 'rosario', 'practica'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localGraphStoreProvider.overrideWith((ref) async => store),
        ],
        child: MaterialApp(
          theme: goldenTheme(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Brain3dScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Brain3dScreen),
      matchesGoldenFile('images/brain3d_summary.png'),
    );
  });
}
