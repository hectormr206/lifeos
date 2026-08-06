/// Where the memory graph's nodes end up in space.
///
/// WHY THIS EXISTS. The 3D brain used `3d-force-graph.min.js` — 1.3 MB of
/// Three.js — inside a WebView. `webview_flutter` has no Linux implementation,
/// so on the desktop build the platform view never mounted and the user saw
/// NOTHING where the phone showed their whole graph. Same cause as the avatar
/// rendering only its head.
///
/// WHY IT IS SEPARATE FROM THE PAINTER. "Does it settle", "do connected nodes
/// end up near each other", "can two nodes overlap" are questions about
/// numbers. Answering them through screenshots is how you end up unable to tell
/// a physics bug from a rendering one.
///
/// THE ALGORITHM is Fruchterman-Reingold in three dimensions: every pair
/// repels, every edge attracts, and a temperature that decays each step caps
/// how far anything may move — which is what makes it converge instead of
/// oscillating. O(n²) per step, which is fine and deliberate: the payload caps
/// the graph at a few hundred nodes, and a quadtree would add real complexity
/// to buy speed nobody is short of.
library;

import 'dart:math' as math;

/// A point in the layout's space.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);

  final double x;
  final double y;
  final double z;

  double distanceTo(Vec3 other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})';
}

class ForceLayout {
  ForceLayout({
    required List<String> nodeIds,
    required List<(String, String)> edges,
    required int seed,
  })  : _ids = List.unmodifiable(nodeIds),
        // Edges may name nodes outside the set: the payload truncates to a node
        // cap, so a kept node can hold an edge to a dropped one. Dereferencing
        // that would crash the screen showing the user their own memory.
        _edges = List.unmodifiable([
          for (final e in edges)
            if (nodeIds.contains(e.$1) && nodeIds.contains(e.$2)) e,
        ]) {
    _seedPositions(seed);
  }

  /// Below this the layout is called settled. An animation that never converges
  /// keeps a CPU busy forever — on a laptop that is battery nobody agreed to
  /// spend.
  static const double restEnergy = 0.05;

  static const int _maxSteps = 400;
  static const double _idealDistance = 8;
  static const double _initialTemperature = 12;

  final List<String> _ids;
  final List<(String, String)> _edges;
  final Map<String, Vec3> _positions = {};

  int _step = 0;
  double _energy = double.infinity;

  Map<String, Vec3> get positions => Map.unmodifiable(_positions);

  /// Total movement in the last step — the convergence measure.
  double get energy => _energy;

  bool get done => _ids.isEmpty || _energy < restEnergy || _step >= _maxSteps;

  void _seedPositions(int seed) {
    // A seeded PRNG, not Random(): the layout must be reproducible, or a bug
    // report about "the graph looks wrong" cannot be acted on and the golden
    // test could not exist at all.
    final random = math.Random(seed);
    if (_ids.length == 1) {
      // One memory belongs in the middle, not wherever the PRNG points.
      _positions[_ids.first] = Vec3.zero;
      return;
    }
    for (final id in _ids) {
      _positions[id] = Vec3(
        (random.nextDouble() - 0.5) * _idealDistance * 2,
        (random.nextDouble() - 0.5) * _idealDistance * 2,
        (random.nextDouble() - 0.5) * _idealDistance * 2,
      );
    }
  }

  /// Run one step. Exposed so the screen can animate the graph unfolding
  /// rather than snapping to its final shape.
  void step() {
    if (done) return;
    _step++;

    // Temperature decays linearly to zero: the cap on movement shrinks each
    // step, which is what turns a jittering cloud into a settled shape.
    final temperature = _initialTemperature * (1 - _step / _maxSteps);
    final displacement = {for (final id in _ids) id: [0.0, 0.0, 0.0]};

    // Repulsion: every pair pushes apart. Without it everything collapses to a
    // point, and overlapping nodes render as one — silently under-reporting
    // how much the user actually remembers.
    for (var i = 0; i < _ids.length; i++) {
      for (var j = i + 1; j < _ids.length; j++) {
        final a = _positions[_ids[i]]!;
        final b = _positions[_ids[j]]!;
        var dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
        var dist = math.sqrt(dx * dx + dy * dy + dz * dz);
        if (dist < 0.01) {
          // Exactly coincident: nudge deterministically rather than dividing
          // by zero. Uses the indices so it stays reproducible.
          dx = (i - j).toDouble();
          dy = 0.01;
          dz = 0.01;
          dist = math.sqrt(dx * dx + dy * dy + dz * dz);
        }
        final force = (_idealDistance * _idealDistance) / dist;
        final ux = dx / dist, uy = dy / dist, uz = dz / dist;
        displacement[_ids[i]]![0] += ux * force;
        displacement[_ids[i]]![1] += uy * force;
        displacement[_ids[i]]![2] += uz * force;
        displacement[_ids[j]]![0] -= ux * force;
        displacement[_ids[j]]![1] -= uy * force;
        displacement[_ids[j]]![2] -= uz * force;
      }
    }

    // Attraction along edges. This is the single claim the picture makes:
    // things near each other are related.
    for (final (from, to) in _edges) {
      final a = _positions[from]!;
      final b = _positions[to]!;
      final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
      final dist = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 0.01);
      final force = (dist * dist) / _idealDistance;
      final ux = dx / dist, uy = dy / dist, uz = dz / dist;
      displacement[from]![0] -= ux * force;
      displacement[from]![1] -= uy * force;
      displacement[from]![2] -= uz * force;
      displacement[to]![0] += ux * force;
      displacement[to]![1] += uy * force;
      displacement[to]![2] += uz * force;
    }

    var moved = 0.0;
    for (final id in _ids) {
      final d = displacement[id]!;
      final length = math.max(math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]), 1e-9);
      // Never move further than the temperature allows — the convergence rule.
      final capped = math.min(length, temperature);
      final p = _positions[id]!;
      _positions[id] = Vec3(
        p.x + d[0] / length * capped,
        p.y + d[1] / length * capped,
        p.z + d[2] / length * capped,
      );
      moved += capped;
    }
    _energy = _ids.isEmpty ? 0 : moved / _ids.length;
  }

  /// Run until settled. Used by tests and by the initial layout; the screen
  /// steps frame by frame so the graph is seen to unfold.
  void settle() {
    if (_ids.isEmpty) {
      _energy = 0;
      return;
    }
    while (!done) {
      step();
    }
  }
}
