// A big graph must not freeze the screen while it is laid out.
//
// Measured on this machine with the payload's own cap of 500 nodes: 8.3 s of
// force layout, all of it inside the widget's constructor, all of it on the UI
// thread. Today's graph is 23 nodes and takes 71 ms — but the user's whole
// point is that it GROWS: "conforme más le vayamos contando de nuestras vidas,
// vamos a llegar al mismo punto".
//
// So the work moves off the UI thread. What is pinned here is the part that
// makes that safe: the off-thread path must produce EXACTLY the same graph as
// the inline one, or the picture would silently depend on how big it is.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/force_layout.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_view.dart';

void main() {
  ({List<String> ids, List<(String, String)> edges}) graph(int n) => (
        ids: [for (var i = 0; i < n; i++) 'n$i'],
        edges: [
          for (var i = 1; i < n; i++)
            if (i % 3 != 0) ('n${i % 5}', 'n$i'),
        ],
      );

  test('the same graph settles identically whichever path runs it', () {
    final g = graph(40);
    final inline = ForceLayout(nodeIds: g.ids, edges: g.edges, seed: 9)
      ..settle();
    final off = settledPositions(nodeIds: g.ids, edges: g.edges, seed: 9);

    for (final id in g.ids) {
      expect(off[id]!.x, closeTo(inline.positions[id]!.x, 1e-9));
      expect(off[id]!.y, closeTo(inline.positions[id]!.y, 1e-9));
      expect(off[id]!.z, closeTo(inline.positions[id]!.z, 1e-9));
    }
  });

  test('a layout can adopt positions computed elsewhere, already settled', () {
    // Adopting has to mean DONE: a layout that keeps stepping after adopting
    // would animate away from the shape that was just computed, and the ticker
    // would never stop.
    final g = graph(12);
    final positions = settledPositions(nodeIds: g.ids, edges: g.edges, seed: 4);
    final layout = ForceLayout(
      nodeIds: g.ids,
      edges: g.edges,
      seed: 4,
      warmupSteps: 0,
    )..adopt(positions);

    expect(layout.done, isTrue);
    expect(layout.positions['n3']!.x, closeTo(positions['n3']!.x, 1e-9));
  });

  test('positions survive the trip as plain numbers', () {
    // What crosses an isolate boundary is data, not objects. If the encoding
    // loses the z axis the graph silently flattens, which looks like a
    // rendering bug and is not one.
    final g = graph(15);
    final original = settledPositions(nodeIds: g.ids, edges: g.edges, seed: 2);
    final round = decodeLayoutPositions(encodeLayoutPositions(original));

    for (final id in g.ids) {
      expect(round[id]!.x, original[id]!.x);
      expect(round[id]!.y, original[id]!.y);
      expect(round[id]!.z, original[id]!.z);
    }
  });

  testWidgets('a big graph shows progress, then the settled graph',
      (tester) async {
    // Just over the threshold, so the isolate path runs without making the
    // suite wait the full eight seconds the cap would cost.
    final n = kBrain3dLayoutOffThreadAbove + 10;
    final g = graph(n);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Brain3dView(
          nodes: [
            for (final id in g.ids) Brain3dVisualNode(id: id, label: id, color: Colors.teal),
          ],
          edges: g.edges,
        ),
      ),
    ));
    await tester.pump();

    // Not a half-settled scramble while it works.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // runAsync, because the isolate does REAL work on real time and the test
    // binding's fake clock would otherwise wait for something that cannot
    // happen inside it.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the isolate result never arrived');
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
