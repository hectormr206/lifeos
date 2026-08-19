/// The memory graph, drawn natively.
///
/// It used to be `3d-force-graph.min.js` — 1.3 MB of Three.js — inside a
/// WebView. `webview_flutter` has no Linux implementation, so on the desktop
/// build the platform view never mounted and the user saw NOTHING where the
/// phone showed their whole graph. Exactly the failure the avatar had.
///
/// WHAT "3D" MEANS HERE. The layout is genuinely three-dimensional (see
/// [ForceLayout]); this projects it with perspective, so nodes further away are
/// smaller and dimmer, and dragging rotates the cloud. It is not a WebGL scene
/// and does not pretend to be — but the spatial reading, which is the whole
/// point of laying memories out in space, survives, and it survives on every
/// platform instead of one.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../domain/force_layout.dart';
import '../domain/label_placement.dart';

/// One node as the view needs it: where it goes, what colour, what it says.
class Brain3dVisualNode {
  const Brain3dVisualNode({
    required this.id,
    required this.label,
    required this.color,
    this.radius = 4,
  });

  final String id;
  final String label;
  final Color color;
  final double radius;
}

class Brain3dView extends StatefulWidget {
  const Brain3dView({
    super.key,
    required this.nodes,
    required this.edges,
    this.onNodeTap,
    this.seed = 7,
  });

  final List<Brain3dVisualNode> nodes;
  final List<(String, String)> edges;
  final void Function(Brain3dVisualNode node)? onNodeTap;

  /// Fixed by default so the same graph looks the same on every open —
  /// a memory map that rearranged itself each visit would be unreadable.
  final int seed;

  @override
  State<Brain3dView> createState() => _Brain3dViewState();
}

class _Brain3dViewState extends State<Brain3dView>
    with SingleTickerProviderStateMixin {
  late ForceLayout _layout;
  late Ticker _ticker;

  /// Ticker time at the previous frame, so each frame advances the simulation
  /// by the time that actually passed.
  Duration _lastElapsed = Duration.zero;

  double _yaw = 0.6;
  double _pitch = 0.3;
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(covariant Brain3dView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes.length != widget.nodes.length ||
        oldWidget.edges.length != widget.edges.length) {
      _ticker.dispose();
      _build();
    }
  }

  void _build() {
    _layout = ForceLayout(
      nodeIds: [for (final n in widget.nodes) n.id],
      edges: widget.edges,
      seed: widget.seed,
    );
    // Stepped on a ticker rather than settled up front so the graph is SEEN to
    // unfold. It also stops on its own: the ticker halts the moment the layout
    // converges, so an idle screen costs nothing.
    //
    // Driven by ELAPSED TIME, not by frame. One step per frame made the whole
    // animation twice as fast on a 120 Hz phone as on a 60 Hz one — measured at
    // 3.33 s against 6.65 s — which is half of why this "se alocaba". The other
    // half, the violent opening, is now warmed up before the first paint.
    _lastElapsed = Duration.zero;
    _ticker = createTicker((elapsed) {
      if (_layout.done) {
        _ticker.stop();
        return;
      }
      final delta = elapsed - _lastElapsed;
      _lastElapsed = elapsed;
      setState(() => _layout.advance(delta));
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion && !_layout.done) {
      // Respect reduced motion by jumping to the settled shape rather than
      // animating there. Also what keeps widget tests able to settle.
      _layout.settle();
      _ticker.stop();
    }

    return GestureDetector(
      onScaleStart: (_) {},
      onScaleUpdate: (details) => setState(() {
        _yaw += details.focalPointDelta.dx * 0.01;
        _pitch = (_pitch + details.focalPointDelta.dy * 0.01)
            .clamp(-math.pi / 2, math.pi / 2);
        if (details.scale != 1.0) {
          _zoom = (_zoom * details.scale).clamp(0.4, 4.0);
        }
      }),
      onTapUp: widget.onNodeTap == null ? null : _handleTap,
      child: CustomPaint(
        painter: Brain3dPainter(
          nodes: widget.nodes,
          edges: widget.edges,
          positions: _layout.positions,
          yaw: _yaw,
          pitch: _pitch,
          zoom: _zoom,
          background: Theme.of(context).colorScheme.surface,
        ),
        size: Size.infinite,
      ),
    );
  }

  void _handleTap(TapUpDetails details) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final projected = Brain3dPainter.project(
      nodes: widget.nodes,
      positions: _layout.positions,
      size: box.size,
      yaw: _yaw,
      pitch: _pitch,
      zoom: _zoom,
    );
    // Nearest node within a finger-sized radius. Front-most wins, because that
    // is the one the user can see.
    Brain3dVisualNode? hit;
    var bestDepth = -double.infinity;
    for (final p in projected) {
      if ((p.offset - details.localPosition).distance <= 24 &&
          p.depth > bestDepth) {
        hit = p.node;
        bestDepth = p.depth;
      }
    }
    if (hit != null) widget.onNodeTap!(hit);
  }
}

/// A node after projection: where it lands and how near the camera it is.
class ProjectedNode {
  const ProjectedNode(this.node, this.offset, this.depth, this.scale);

  final Brain3dVisualNode node;
  final Offset offset;

  /// Higher is nearer the camera. Drives paint order and dimming.
  final double depth;
  final double scale;
}

class Brain3dPainter extends CustomPainter {
  const Brain3dPainter({
    required this.nodes,
    required this.edges,
    required this.positions,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.background,
  });

  final List<Brain3dVisualNode> nodes;
  final List<(String, String)> edges;
  final Map<String, Vec3> positions;
  final double yaw;
  final double pitch;
  final double zoom;
  final Color background;

  /// Distance from the camera to the origin. Large enough that perspective
  /// reads as depth rather than as a fisheye.
  static const double _cameraDistance = 60;

  /// How much nearness may magnify, and farness may shrink.
  ///
  /// Chosen so depth stays legible while a node can never dominate the screen
  /// or vanish from it: a 4 px dot renders between 3 px and 11 px, a label
  /// between 6 pt and 20 pt.
  static const double _minPerspective = 0.55;
  static const double _maxPerspective = 2.0;

  /// Where one point lands on screen, relative to the centre, at [scale].
  /// Shared so the measuring pass and the drawing pass cannot drift apart.
  static Offset _flatten(Vec3 p, double cx, double cy, double cz, double yaw,
      double pitch, double scale) {
    final px = p.x - cx, py = p.y - cy, pz = p.z - cz;
    final x1 = px * math.cos(yaw) + pz * math.sin(yaw);
    final z1 = -px * math.sin(yaw) + pz * math.cos(yaw);
    final y2 = py * math.cos(pitch) - z1 * math.sin(pitch);
    final z2 = py * math.sin(pitch) + z1 * math.cos(pitch);
    final perspective = (_cameraDistance /
            math.max(_cameraDistance + z2 * 0.6, 1.0))
        .clamp(_minPerspective, _maxPerspective);
    return Offset(x1 * scale * perspective, y2 * scale * perspective);
  }

  static List<ProjectedNode> project({
    required List<Brain3dVisualNode> nodes,
    required Map<String, Vec3> positions,
    required Size size,
    required double yaw,
    required double pitch,
    required double zoom,
  }) {
    final centre = Offset(size.width / 2, size.height / 2);
    if (positions.isEmpty) return const [];

    // Centre on the CLOUD, not on the origin. A settled layout drifts — its
    // centre of mass is wherever the forces left it — so projecting about the
    // origin renders the graph small and pushed into a corner, which is
    // exactly what the first golden showed.
    var cx = 0.0, cy = 0.0, cz = 0.0;
    for (final p in positions.values) {
      cx += p.x;
      cy += p.y;
      cz += p.z;
    }
    final n = positions.length;
    cx /= n;
    cy /= n;
    cz /= n;

    // Fit the cloud to the viewport instead of assuming a scale: a graph of 3
    // nodes and one of 300 occupy wildly different volumes.
    var extent = 1.0;
    for (final p in positions.values) {
      extent = math.max(
          extent,
          math.max((p.x - cx).abs(),
              math.max((p.y - cy).abs(), (p.z - cz).abs())));
    }
    // A provisional scale, refined below. Fitting by the 3D extent alone is
    // what left the graph occupying a fifth of a phone screen: after the yaw,
    // the pitch and the perspective divide, the PROJECTED spread is always
    // smaller than the cloud's radius — and by a factor that changes with every
    // rotation, so no constant can compensate for it.
    final provisional = (math.min(size.width, size.height) * 0.34) / extent;

    // TURN THE CLOUD TO FACE THE VIEWER before anything else.
    //
    // Reported from the laptop: two dots twenty pixels apart in the middle of a
    // 2560-wide black field. They were separated almost entirely along the
    // CAMERA AXIS, so they projected onto the same place — and no fit can undo
    // that, because scaling two points that land together just scales the same
    // point. Measured before this: a spread of exactly 0.0 px.
    //
    // The rule is one line: whichever axis the memories vary LEAST along is the
    // one that should point at the camera. Then the two axes they vary most
    // along are the two you can actually see.
    final base = _facingRotation(positions, cx, cy, cz);
    final cosY = math.cos(yaw + base.yaw), sinY = math.sin(yaw + base.yaw);
    final cosP = math.cos(pitch + base.pitch), sinP = math.sin(pitch + base.pitch);

    // Pass 1 measures where the nodes actually land; pass 2 scales that box to
    // the viewport. Two cheap loops over a capped node count, and the graph
    // fills the screen at any angle instead of hiding in the middle of it.
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in positions.values) {
      final o = _flatten(p, cx, cy, cz, yaw + base.yaw, pitch + base.pitch,
          provisional);
      minX = math.min(minX, o.dx);
      maxX = math.max(maxX, o.dx);
      minY = math.min(minY, o.dy);
      maxY = math.max(maxY, o.dy);
    }
    // 0.82 leaves room for the LABELS, which sit outside the node they name; a
    // graph scaled to the very edge pushes half of them off-screen.
    final spanX = math.max(maxX - minX, 1.0);
    final spanY = math.max(maxY - minY, 1.0);
    final fit = provisional *
        math.min(size.width * 0.82 / spanX, size.height * 0.82 / spanY) *
        zoom;

    final out = <ProjectedNode>[];
    for (final node in nodes) {
      final p = positions[node.id];
      if (p == null) continue;
      // Recentred, then yaw about Y, then pitch about X.
      final px = p.x - cx, py = p.y - cy, pz = p.z - cz;
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;

      // Perspective divide. Clamped so a node that drifts behind the camera
      // does not invert and fly off to infinity.
      // BOUNDED, not merely non-zero.
      //
      // The old clamp stopped a division by zero and nothing else: a node close
      // to the camera drove the denominator to 1 and this factor to SIXTY. A
      // 4 px node rendered at 336 px and an 11 px label at 660 — one memory
      // filling a phone screen, which is what the user photographed. The far
      // side had the mirror problem: a speck nobody can see or tap.
      //
      // Depth should say "nearer" and "further", never "everything" and
      // "nothing".
      final perspective = (_cameraDistance /
              math.max(_cameraDistance + z2 * 0.6, 1.0))
          .clamp(_minPerspective, _maxPerspective);
      out.add(ProjectedNode(
        node,
        centre + Offset(x1 * fit * perspective, y2 * fit * perspective),
        -z2,
        perspective,
      ));
    }
    // Painter's algorithm: far first, so near nodes overlap them.
    out.sort((a, b) => a.depth.compareTo(b.depth));
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;
    final projected =
        project(nodes: nodes, positions: positions, size: size, yaw: yaw, pitch: pitch, zoom: zoom);
    final byId = {for (final p in projected) p.node.id: p};

    // Edges under the nodes, and faint: they are context, not content. A graph
    // where the links shout is unreadable past about thirty nodes.
    final edgePaint = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final (from, to) in edges) {
      final a = byId[from], b = byId[to];
      if (a == null || b == null) continue;
      edgePaint.color = Color.lerp(a.node.color, b.node.color, 0.5)!
          .withValues(alpha: 0.22);
      canvas.drawLine(a.offset, b.offset, edgePaint);
    }

    for (final p in projected) {
      // Depth cues do the work WebGL lighting would: nearer is bigger and more
      // opaque. Without them the projection reads as a flat scatter.
      final paint = Paint()..color = p.node.color.withValues(alpha: 0.45 + 0.55 * p.scale);
      final radius = p.node.radius * p.scale * 1.4;
      canvas.drawCircle(p.offset, radius, paint);
    }

    // Labels are laid out SEPARATELY, after every circle is drawn, because
    // deciding whether one fits requires knowing where the others went.
    //
    // Drawing each label as its node came up produced the pile the user
    // photographed: "presión 109/77 pulso 56" stacked over
    // "presión 125/78 pulso 82" until none of it could be read. A label nobody
    // can read is worse than no label — it hides the legible ones and makes the
    // whole screen look broken.
    final labelled = [
      for (final p in projected)
        if (p.scale >= 0.95 && p.node.label.isNotEmpty) p,
    ]..sort((a, b) => b.scale.compareTo(a.scale));

    final painters = <TextPainter>[];
    final offsets = <Offset>[];
    final boxes = <Rect>[];
    for (final p in labelled) {
      final radius = p.node.radius * p.scale * 1.4;
      final painter = TextPainter(
        text: TextSpan(
          text: p.node.label.length > 28
              ? '${p.node.label.substring(0, 27)}…'
              : p.node.label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55 + 0.45 * p.scale),
            fontSize: 11 * p.scale,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 160);
      // Flip the label to the left when it would run off the right edge.
      // A truncated label on a memory map is worse than a shifted one: the
      // user cannot tell which memory the node IS.
      final wouldOverflow = p.offset.dx + radius + 4 + painter.width > size.width;
      final dx = wouldOverflow ? -(radius + 4 + painter.width) : radius + 4;
      final at = p.offset + Offset(dx, -painter.height / 2);
      painters.add(painter);
      offsets.add(at);
      boxes.add(Rect.fromLTWH(at.dx, at.dy, painter.width, painter.height));
    }

    // Nearest first, so the most prominent label is the one that survives a
    // pile-up rather than whichever happened to be drawn last.
    for (final i in visibleLabelIndices(boxes)) {
      painters[i].paint(canvas, offsets[i]);
    }
  }

  @override
  bool shouldRepaint(covariant Brain3dPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      !identical(old.positions, positions) ||
      old.nodes.length != nodes.length;
}

/// Which way to turn the cloud so its widest face is the one you see.
///
/// Whichever axis the memories vary LEAST along is the one that should point at
/// the camera; the two they vary most along are then both on screen. Without
/// this a graph whose nodes differ mainly in depth renders as a single dot —
/// measured at exactly 0.0 px of spread, which is what the laptop showed.
///
/// Three canonical quarter-turns, not a full principal-axis decomposition: the
/// input is a force layout with no meaningful orientation of its own, so the
/// only thing worth fixing is which axis faces the viewer. Anything more would
/// be arithmetic nobody could check by looking at the screen.
({double yaw, double pitch}) _facingRotation(
  Map<String, Vec3> positions,
  double cx,
  double cy,
  double cz,
) {
  if (positions.length < 2) return (yaw: 0, pitch: 0);

  var sx = 0.0, sy = 0.0, sz = 0.0;
  for (final p in positions.values) {
    sx += (p.x - cx) * (p.x - cx);
    sy += (p.y - cy) * (p.y - cy);
    sz += (p.z - cz) * (p.z - cz);
  }

  // Smallest spread goes to the camera axis (z).
  if (sz <= sx && sz <= sy) return (yaw: 0, pitch: 0);
  if (sx <= sy) return (yaw: math.pi / 2, pitch: 0); // x becomes depth
  return (yaw: 0, pitch: math.pi / 2); // y becomes depth
}
