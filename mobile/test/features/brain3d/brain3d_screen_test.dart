// Proves the Cerebro 3D screen builds its graph from the LOCAL store via the
// payload provider. On the test host there is no WebView platform
// (WebViewPlatform.instance == null), so the screen renders its textual
// the graph itself, natively. There is no longer a WebView to be absent from:
// the renderer is a CustomPainter, so the same widget runs on the Pixel, on
// Linux and in this test — which is the point of the rewrite. The old summary
// is now reserved for an EMPTY graph, where a blank canvas would read as a bug.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_view.dart';

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

  /// What the screen ASKED the store to do. The panel's two destructive
  /// actions are the only place in this app where a tap removes something the
  /// user told Axi, so the test asserts the call, not the repaint.
  final List<String> forgotten = [];
  final List<(String loser, String winner)> merged = [];

  @override
  Future<bool> softDeleteNode(String uuid) async {
    forgotten.add(uuid);
    return true;
  }

  @override
  Future<bool> mergeNodes({
    required String loserUuid,
    required String winnerUuid,
  }) async {
    merged.add((loserUuid, winnerUuid));
    return true;
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
  _cleanupTests();
  testWidgets('renders the graph itself, on every platform', (tester) async {
    final t = DateTime.utc(2026, 1, 1);
    final store = _FakeLocalGraphStore(
      // THREE nodes, not two: fewer than three renders as a sentence now.
      // Two dots in a black field read as a broken screen — reported twice
      // from a laptop — and a graph with nothing to relate is not a graph.
      nodes: [_node('f1', 'fact'), _node('p1', 'person'), _node('f2', 'fact')],
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
    // NOT pumpAndSettle: the layout animates until it converges. Two pumps let
    // the payload future resolve, which is what this test is about.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Cerebro 3D'), findsOneWidget);
    expect(find.byType(Brain3dView), findsOneWidget,
        reason: 'a non-empty graph draws the graph, not a text summary');
    expect(find.text('2 nodos · 1 enlaces en el grafo local'), findsNothing);
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

  group('the three actions of the original Cerebro', () {
    GraphNodeRecord named(String uuid, String label, DateTime when) =>
        GraphNodeRecord(
          uuid: uuid,
          kind: 'person',
          label: label,
          createdAt: when,
          updatedAt: when,
        );

    _FakeLocalGraphStore threePeople({DateTime? when}) {
      final t = when ?? DateTime.now().subtract(const Duration(days: 1));
      return _FakeLocalGraphStore(
        nodes: [
          named('a', 'Ana', t),
          named('a2', 'ana', t),
          named('s', 'Sofía', t),
        ],
      );
    }

    Future<void> open(WidgetTester tester, LocalGraphStore store) async {
      await tester.pumpWidget(_app(store));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('with nothing selected it shows the week\'s news',
        (tester) async {
      await open(tester, threePeople());

      expect(find.text('Novedades de la semana'), findsOneWidget);
      // And the news are the memories themselves, not a count.
      expect(find.text('Ana'), findsOneWidget);
    });

    testWidgets('an old graph shows no news rather than filler',
        (tester) async {
      await open(
        tester,
        threePeople(when: DateTime.now().subtract(const Duration(days: 90))),
      );

      // Inventing a "novedad" in a memory app is a lie about the user's life.
      expect(find.text('Ana'), findsNothing);
    });

    testWidgets('tapping a news item opens that memory', (tester) async {
      await open(tester, threePeople());
      await tester.tap(find.text('Ana'));
      await tester.pump();

      expect(find.text('Olvidar este nodo'), findsOneWidget);
    });

    testWidgets('forgetting asks first, and a cancel forgets nothing',
        (tester) async {
      final store = threePeople();
      await open(tester, store);
      await tester.tap(find.text('Ana'));
      await tester.pump();

      await tester.ensureVisible(find.text('Olvidar este nodo'));
      await tester.tap(find.text('Olvidar este nodo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(store.forgotten, isEmpty,
          reason: 'a cancelled dialog must never delete a memory');
    });

    testWidgets('confirming actually forgets that node', (tester) async {
      final store = threePeople();
      await open(tester, store);
      await tester.tap(find.text('Ana'));
      await tester.pump();

      await tester.ensureVisible(find.text('Olvidar este nodo'));
      await tester.tap(find.text('Olvidar este nodo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Olvidar'));
      await tester.pumpAndSettle();

      expect(store.forgotten, ['a']);
    });

    testWidgets('merging folds the OTHER node into the one on screen',
        (tester) async {
      // Direction matters and is invisible: whichever node survives keeps its
      // label, and getting it backwards silently renames the user's memory.
      final store = threePeople();
      await open(tester, store);
      await tester.tap(find.text('Ana'));
      await tester.pump();

      await tester.ensureVisible(find.text('Fusionar con…'));
      await tester.tap(find.text('Fusionar con…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ana').last);
      await tester.pumpAndSettle();

      expect(store.merged, [('a2', 'a')],
          reason: 'the node you are looking at is the one that survives');
    });

    testWidgets('the merge picker never offers the node itself',
        (tester) async {
      final store = threePeople();
      await open(tester, store);
      await tester.tap(find.text('Ana'));
      await tester.pump();

      await tester.ensureVisible(find.text('Fusionar con…'));
      await tester.tap(find.text('Fusionar con…'));
      await tester.pumpAndSettle();

      // Only the title of the panel behind it; no row to tap.
      expect(find.text('Ana'), findsOneWidget);
    });
  });

  group('the news panel never takes the screen from the graph', () {
    // Measured on the test Pixel with 860: twelve news items on a phone-sized
    // screen and the panel filled EVERYTHING — the brain was not visible at
    // all. A bottom-anchored Positioned has no height of its own, so a
    // shrink-wrapped list simply grows until it owns the screen.
    //
    // The widget tests passed because they asserted that texts existed. Text
    // existing is not the same as the user being able to see the graph, and
    // this is the second time in this session that a layout regression got
    // through a green test for exactly that reason.

    testWidgets('a busy week still leaves most of the screen to the brain',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final now = DateTime.now();
      final store = _FakeLocalGraphStore(
        nodes: [
          for (var i = 0; i < 20; i++)
            GraphNodeRecord(
              uuid: 'n$i',
              kind: 'fact',
              label: 'memoria $i',
              createdAt: now.subtract(Duration(hours: i)),
              updatedAt: now,
            ),
        ],
      );

      await tester.pumpWidget(_app(store));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final screen = tester.getSize(find.byType(Brain3dScreen)).height;
      final panel = tester.getSize(find.byKey(const ValueKey('brain3d-panel'))).height;

      expect(panel, lessThan(screen * 0.5),
          reason: 'the panel covered the graph it is supposed to sit beside');
      expect(find.byType(Brain3dView), findsOneWidget);
    });
  });

  testWidgets('the merge picker only offers nodes of the same kind',
      (tester) async {
    // Seen on the test Pixel with 862: selecting the person "Yo" offered to
    // fuse it with "peso 82 kg". A weight is not a duplicate of a person, and
    // a picker that offers the whole graph invites a merge that destroys both
    // rows — irreversibly, on every device.
    final now = DateTime.now();
    GraphNodeRecord row(String uuid, String kind, String label) =>
        GraphNodeRecord(
          uuid: uuid,
          kind: kind,
          label: label,
          createdAt: now,
          updatedAt: now,
        );

    final store = _FakeLocalGraphStore(nodes: [
      row('p1', 'person', 'Ana'),
      row('p2', 'person', 'ana'),
      row('f1', 'fact', 'peso 82 kg'),
    ]);

    await tester.pumpWidget(_app(store));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Ana'));
    await tester.pump();
    await tester.ensureVisible(find.text('Fusionar con…'));
    await tester.tap(find.text('Fusionar con…'));
    await tester.pumpAndSettle();

    expect(find.text('ana'), findsOneWidget);
    expect(find.text('peso 82 kg'), findsNothing,
        reason: 'a weight is not a duplicate of a person');
  });
}

// ── Limpieza de nodos sin significado ────────────────────────────────────────
//
// El filtro nuevo impide que entren más, pero el Cerebro del usuario ya tiene
// meses de "la otra persona", "Axi" y "esposa_nació_en" dentro. Esto prueba lo
// único que importa de un botón que BORRA: que enseña qué va a borrar, que
// espera un sí, y que un no no toca nada.
GraphNodeRecord _labelled(String uuid, String kind, String label) {
  final t = DateTime.utc(2026, 6, 1);
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: label,
    data: const {'source': 'relation_extractor'},
    createdAt: t,
    updatedAt: t,
  );
}

void _cleanupTests() {
  group('limpiar el Cerebro', () {
    testWidgets('pregunta antes de borrar, y dice cuántos', (tester) async {
      final store = _FakeLocalGraphStore(nodes: [
        _labelled('n1', 'person', 'la otra persona'),
        _labelled('n2', 'fact', 'esposa_nació_en'),
        _labelled('n3', 'person', 'Celia García Mateo'),
      ]);
      await tester.pumpWidget(_app(store));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Limpiar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('¿Olvidar 2'), findsOneWidget);
      expect(
        store.forgotten,
        isEmpty,
        reason: 'preguntar no puede haber borrado ya',
      );
    });

    testWidgets('cancelar no toca nada', (tester) async {
      final store = _FakeLocalGraphStore(nodes: [
        _labelled('n1', 'person', 'la otra persona'),
      ]);
      await tester.pumpWidget(_app(store));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Limpiar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();

      expect(store.forgotten, isEmpty);
    });

    testWidgets('al confirmar olvida sólo lo que sobra', (tester) async {
      final store = _FakeLocalGraphStore(nodes: [
        _labelled('n1', 'person', 'la otra persona'),
        _labelled('n2', 'fact', 'esposa_nació_en'),
        _labelled('n3', 'person', 'Celia García Mateo'),
        _labelled('n4', 'fact', 'Nos casamos el 6 de septiembre de 2018'),
      ]);
      await tester.pumpWidget(_app(store));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Limpiar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Olvidarlos'));
      await tester.pumpAndSettle();

      // El orden lo decide cómo el Cerebro agrupa por tipo; lo que importa es
      // QUÉ se borró y qué no.
      expect(store.forgotten.toSet(), {'n1', 'n2'});
    });

    testWidgets('sin nada que limpiar, lo dice y no abre nada',
        (tester) async {
      final store = _FakeLocalGraphStore(nodes: [
        _labelled('n3', 'person', 'Celia García Mateo'),
      ]);
      await tester.pumpWidget(_app(store));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Limpiar'));
      await tester.pumpAndSettle();

      expect(find.text('No encontré nada que sobre.'), findsOneWidget);
      expect(find.textContaining('¿Olvidar'), findsNothing);
    });
  });
}
