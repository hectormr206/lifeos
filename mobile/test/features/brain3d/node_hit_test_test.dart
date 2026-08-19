// Tapping a memory to see what it is.
//
// The desktop Cerebro has had this since the beginning: click a node, read its
// details, merge it or forget it. The phone port shipped without it and painted
// every label permanently instead — which is both less useful and uglier.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/node_hit_test.dart';

void main() {
  HitCandidate at(String id, double x, double y,
          {double radius = 6, double depth = 0}) =>
      HitCandidate(id: id, centre: Offset(x, y), radius: radius, depth: depth);

  test('a tap on a node selects it', () {
    expect(nodeAt(const Offset(100, 100), [at('a', 100, 100)]), 'a');
  });

  test('a small dot is still tappable', () {
    // A 6 px circle is not a target a finger can hit. Missing reads as a dead
    // screen; the cost of being generous is picking a neighbour, which the user
    // sees at once and fixes with another tap.
    expect(nodeAt(const Offset(115, 100), [at('a', 100, 100)]), 'a');
  });

  test('empty space selects NOTHING', () {
    // "Nothing" has to be a real answer: it is how the details panel closes.
    expect(nodeAt(const Offset(400, 400), [at('a', 100, 100)]), isNull);
  });

  test('the front-most node wins an overlap', () {
    final hit = nodeAt(const Offset(100, 100), [
      at('detras', 100, 100, depth: -5),
      at('delante', 100, 100, depth: 5),
    ]);

    expect(hit, 'delante');
  });

  test('among equals, the nearer centre wins', () {
    final hit = nodeAt(const Offset(100, 100), [
      at('lejos', 118, 100),
      at('cerca', 102, 100),
    ]);

    expect(hit, 'cerca');
  });

  test('an empty graph is not a crash', () {
    expect(nodeAt(const Offset(1, 1), const []), isNull);
  });
}
