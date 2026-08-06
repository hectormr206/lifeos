// The force simulation behind the 3D memory — the part with no pixels in it.
//
// This exists because `3d-force-graph.min.js` (1.3 MB of Three.js in a WebView)
// does not exist on Linux: webview_flutter has no Linux implementation, so the
// desktop build showed nothing at all where the phone showed the graph. Same
// cause as the avatar only rendering its head.
//
// Layout is separated from painting for the reason every simulation should be:
// "does it settle", "is it stable", "do connected nodes end up near each other"
// are questions about numbers, and answering them through screenshots is how
// you end up unable to tell a physics bug from a rendering one.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/force_layout.dart';

ForceLayout _layout(int nodes, List<(int, int)> edges, {int seed = 7}) =>
    ForceLayout(
      nodeIds: [for (var i = 0; i < nodes; i++) 'n$i'],
      edges: [for (final e in edges) ('n${e.$1}', 'n${e.$2}')],
      seed: seed,
    );

void main() {
  test('every node gets a position, in three dimensions', () {
    final layout = _layout(5, [(0, 1), (1, 2)]);

    expect(layout.positions.length, 5);
    for (final p in layout.positions.values) {
      expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, isTrue);
    }
  });

  test('the same seed lays out the same graph identically', () {
    // Determinism is not a nicety here: without it the golden test below could
    // not exist, and neither could a bug report anyone can reproduce.
    final a = _layout(6, [(0, 1), (2, 3), (4, 5)])..settle();
    final b = _layout(6, [(0, 1), (2, 3), (4, 5)])..settle();

    for (final id in a.positions.keys) {
      expect(a.positions[id]!.x, closeTo(b.positions[id]!.x, 1e-9));
      expect(a.positions[id]!.z, closeTo(b.positions[id]!.z, 1e-9));
    }
  });

  test('two nodes never occupy the same point', () {
    // Repulsion's whole job. Overlapping nodes render as one, which silently
    // under-reports how much the user actually remembers.
    final layout = _layout(12, [])..settle();

    final points = layout.positions.values.toList();
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        expect(points[i].distanceTo(points[j]), greaterThan(0.5),
            reason: 'nodes $i and $j collapsed onto each other');
      }
    }
  });

  test('connected nodes settle closer than unconnected ones', () {
    // The single claim the picture makes: proximity means relatedness. If this
    // fails the graph is decorative, and worse, misleading.
    final layout = _layout(6, [(0, 1)])..settle();

    final connected =
        layout.positions['n0']!.distanceTo(layout.positions['n1']!);
    final unconnected =
        layout.positions['n0']!.distanceTo(layout.positions['n4']!);

    expect(connected, lessThan(unconnected));
  });

  test('it settles — the simulation is not perpetual', () {
    // An animation that never converges keeps the CPU busy forever, and on a
    // laptop that is battery the user did not agree to spend.
    final layout = _layout(20, [(0, 1), (1, 2), (3, 4), (5, 6)]);

    layout.settle();

    expect(layout.done, isTrue);
    expect(layout.energy, lessThan(ForceLayout.restEnergy));
  });

  test('an isolated node is still placed, not dropped', () {
    final layout = _layout(3, [(0, 1)])..settle();

    expect(layout.positions.containsKey('n2'), isTrue);
    expect(layout.positions['n2']!.x.isFinite, isTrue);
  });

  test('an empty graph is not a crash', () {
    final layout = ForceLayout(nodeIds: const [], edges: const [], seed: 1);

    layout.settle();

    expect(layout.positions, isEmpty);
    expect(layout.done, isTrue);
  });

  test('an edge naming a node that is not there is ignored', () {
    // The payload truncates to a node cap, so edges CAN point outside the set.
    // Dereferencing one would crash the screen that shows the user's memory.
    final layout = ForceLayout(
      nodeIds: const ['a', 'b'],
      edges: const [('a', 'ghost'), ('a', 'b')],
      seed: 3,
    );

    layout.settle();

    expect(layout.positions.length, 2);
  });

  test('a single node sits at the origin rather than drifting', () {
    final layout = ForceLayout(nodeIds: const ['solo'], edges: const [], seed: 1)
      ..settle();

    expect(layout.positions['solo']!.distanceTo(Vec3.zero), lessThan(1.0));
  });
}
