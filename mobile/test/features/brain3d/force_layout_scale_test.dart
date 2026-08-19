// The layout has to hold its shape as the graph GROWS.
//
// Reported from the laptop with 23 nodes and 28 relations: "se ve todo junto,
// no se ve separado" — a single blob and one stray dot. The same build looked
// right on the phone, which had 13 nodes. Measured on a graph shaped like his:
//
//     minDist = 6.9    maxDist = 1056    ratio = 0.0065
//
// The view frames the graph by its bounding box, so a neighbourhood 6.9 units
// wide inside a cloud 1056 units wide is drawn in under one pixel. Nothing was
// wrong with the renderer: the layout itself was flying apart.
//
// Fruchterman-Reingold's ideal distance is defined RELATIVE to the space the
// graph must occupy — k = f(volume / n). This one used a constant 8, so every
// node added more total repulsion with nothing to balance it, and the cloud
// grew without bound while edge-bound pairs stayed glued together.
//
// These tests pin the property that actually matters to someone looking at the
// screen: the closest pair must not be a rounding error next to the furthest.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/force_layout.dart';

/// A graph shaped like a real memory: hubs (people) with facts hanging off
/// them, a few chains, and one node nothing links to yet.
({List<String> ids, List<(String, String)> edges}) memoryLike(int n) {
  final ids = [for (var i = 0; i < n; i++) 'n$i'];
  final edges = <(String, String)>[
    for (var i = 1; i < n; i++)
      if (i % 3 != 0) ('n${i % 5}', 'n$i'),
    for (var i = 6; i < n - 1; i += 4) ('n$i', 'n${i + 1}'),
  ];
  return (ids: ids, edges: edges);
}

({double min, double max}) spread(Map<String, Vec3> p, List<String> ids) {
  var min = double.infinity, max = 0.0;
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final d = p[ids[i]]!.distanceTo(p[ids[j]]!);
      min = math.min(min, d);
      max = math.max(max, d);
    }
  }
  return (min: min, max: max);
}

void main() {
  // 23 is the reported case; the rest bracket it so a fix tuned to one size
  // cannot pass.
  // 500 is the payload's own cap, so this brackets the whole range the app can
  // ever render — the point being that "it looks fine today" is not the claim.
  for (final n in [5, 13, 23, 60, 150, 300, 500]) {
    test('$n nodes still read as separate points', () {
      final g = memoryLike(n);
      final layout = ForceLayout(nodeIds: g.ids, edges: g.edges, seed: 7);
      layout.settle();
      final s = spread(layout.positions, g.ids);

      // The closest pair against the widest span. At 0.0065 the whole graph
      // was one blob; the eye needs the closest pair to survive the scaling
      // that fits the widest span onto the screen.
      expect(s.min / s.max, greaterThan(0.02),
          reason: 'n=$n collapsed: min=${s.min}, max=${s.max}');
    });

    test('$n nodes stay inside a bounded space', () {
      // Unbounded growth is what produced max=1056 from an ideal distance of
      // 8. Whatever the count, the cloud must stay in the same order of size,
      // or the framing has to keep shrinking everything to fit an outlier.
      final g = memoryLike(n);
      final layout = ForceLayout(nodeIds: g.ids, edges: g.edges, seed: 7);
      layout.settle();
      final s = spread(layout.positions, g.ids);

      expect(s.max, lessThan(kForceLayoutFrameRadius * 2.5),
          reason: 'n=$n flew apart: max=${s.max}');
    });
  }

  test('no two nodes land on top of each other', () {
    // Overlapping nodes render as one and silently under-report how much the
    // user remembers.
    final g = memoryLike(40);
    final layout = ForceLayout(nodeIds: g.ids, edges: g.edges, seed: 3);
    layout.settle();

    expect(spread(layout.positions, g.ids).min, greaterThan(0.5));
  });

  test('a node nothing links to is still placed, not flung away', () {
    // The stray dot in the report. An isolated node feels only repulsion, so
    // without a bound it leaves the frame and drags the framing with it.
    final ids = [for (var i = 0; i < 12; i++) 'n$i'];
    final edges = [for (var i = 1; i < 11; i++) ('n0', 'n$i')];
    final layout = ForceLayout(nodeIds: ids, edges: edges, seed: 5)..settle();
    final p = layout.positions;

    final lonely = p['n11']!;
    final centre = p['n0']!;
    expect(lonely.distanceTo(centre), lessThan(kForceLayoutFrameRadius * 2));
  });
}
