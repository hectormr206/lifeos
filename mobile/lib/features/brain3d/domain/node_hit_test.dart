// Which node a tap landed on.
//
// The desktop Cerebro selects a node on click and shows its details in a side
// panel; the labels live there, not scattered over the graph. That is why it
// reads as a clean constellation while the phone port — which painted every
// label always — read as a pile of words.
//
// Pure, so the rule can be argued about without a widget: nearest node whose
// drawn circle the tap actually touched, front-most first.
import 'dart:ui';

/// A node as it was DRAWN: where it landed and how big it ended up.
class HitCandidate {
  const HitCandidate({
    required this.id,
    required this.centre,
    required this.radius,
    required this.depth,
  });

  final String id;
  final Offset centre;
  final double radius;

  /// Larger is nearer the viewer.
  final double depth;
}

/// Finger-sized, because a 6 px dot is not a target anyone can hit.
///
/// Deliberately generous: missing a tap on a memory reads as "the screen is
/// dead", and the cost of being generous is selecting a neighbour — which the
/// user sees immediately and fixes with another tap.
const double kMinTapRadius = 22;

/// The node under [tap], or null when the tap hit empty space.
///
/// Empty space matters: it is how the panel is dismissed, so "nothing" has to
/// be a real answer rather than the nearest node however far away.
String? nodeAt(Offset tap, List<HitCandidate> candidates) {
  String? best;
  var bestDepth = double.negativeInfinity;
  var bestDistance = double.infinity;

  for (final c in candidates) {
    final reach = c.radius < kMinTapRadius ? kMinTapRadius : c.radius;
    final distance = (c.centre - tap).distance;
    if (distance > reach) continue;

    // Front-most wins; among equals, the closer centre.
    if (c.depth > bestDepth ||
        (c.depth == bestDepth && distance < bestDistance)) {
      best = c.id;
      bestDepth = c.depth;
      bestDistance = distance;
    }
  }
  return best;
}
