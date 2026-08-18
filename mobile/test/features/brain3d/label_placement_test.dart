// Reported with a screenshot: entering the 3D brain showed a pile of
// overlapping words — "presión 109/77 pulso 56" stacked on top of
// "presión 125/78 pulso 82" until none of it was readable.
//
// The rule this pins: a label is drawn only if it does not collide with one
// already drawn, and the caller decides who goes first.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/label_placement.dart';

void main() {
  test('labels that do not touch are all drawn', () {
    final boxes = [
      const Rect.fromLTWH(0, 0, 50, 20),
      const Rect.fromLTWH(200, 0, 50, 20),
      const Rect.fromLTWH(0, 200, 50, 20),
    ];

    expect(visibleLabelIndices(boxes), [0, 1, 2]);
  });

  test('an overlapping label is dropped, not moved', () {
    // Moving it would put the text away from the node it names, which on a
    // memory map is a different kind of lie.
    final boxes = [
      const Rect.fromLTWH(0, 0, 50, 20),
      const Rect.fromLTWH(10, 5, 50, 20),
    ];

    expect(visibleLabelIndices(boxes), [0]);
  });

  test('the first in the list wins', () {
    // The caller passes the nearest-to-camera first, so the most prominent
    // label is the one that survives a pile-up.
    final boxes = [
      const Rect.fromLTWH(10, 5, 50, 20),
      const Rect.fromLTWH(0, 0, 50, 20),
    ];

    expect(visibleLabelIndices(boxes), [0]);
  });

  test('a whole cluster collapses to one readable label', () {
    // The screenshot case: eight labels within a few pixels of each other.
    final boxes = [
      for (var i = 0; i < 8; i++) Rect.fromLTWH(i.toDouble(), 0, 120, 18),
    ];

    expect(visibleLabelIndices(boxes), hasLength(1));
  });

  test('padding keeps labels from touching', () {
    // Exactly adjacent boxes do not "overlap" geometrically, but text that
    // touches is still unreadable.
    final boxes = [
      const Rect.fromLTWH(0, 0, 50, 20),
      const Rect.fromLTWH(50, 0, 50, 20),
    ];

    expect(visibleLabelIndices(boxes, padding: 4), [0]);
    expect(visibleLabelIndices(boxes, padding: 0), [0, 1]);
  });

  test('an empty list is not a crash', () {
    expect(visibleLabelIndices(const []), isEmpty);
  });
}
