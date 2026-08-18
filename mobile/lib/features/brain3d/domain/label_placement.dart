// Which labels get drawn when several nodes land on top of each other.
//
// Every front-facing node used to draw its label unconditionally, so a tight
// cluster rendered as a pile of overlapping words — "presión 109/77 pulso 56"
// stacked over "presión 125/78 pulso 82" until none of it could be read. The
// picture looked broken even when the layout underneath was fine.
//
// A label nobody can read is worse than no label: it hides the ones that are
// legible and makes the whole screen look like a fault.
import 'dart:ui';

/// Indices of the labels to draw, in the order given.
///
/// Greedy and order-dependent BY DESIGN: the caller passes the most important
/// first (nearest to the camera), and each label is kept only if it does not
/// collide with one already kept. Anything smarter would move labels away from
/// the thing they name, which on a memory map is a different kind of lie.
List<int> visibleLabelIndices(List<Rect> boxes, {double padding = 2}) {
  final kept = <Rect>[];
  final indices = <int>[];

  for (var i = 0; i < boxes.length; i++) {
    final box = boxes[i].inflate(padding);
    var collides = false;
    for (final other in kept) {
      if (box.overlaps(other)) {
        collides = true;
        break;
      }
    }
    if (collides) continue;
    kept.add(box);
    indices.add(i);
  }
  return indices;
}
