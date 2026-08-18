// A two-node graph on a wide desktop window.
//
// Reported with a screenshot from the laptop: two dots about twenty pixels
// apart in the middle of a 2560x1430 black field, while the same screen on the
// phone filled comfortably. The difference is not the platform — it is the
// SHAPE of the data. Two nodes projected nearly on top of each other collapse
// one of the spans to almost nothing, and a fit computed from that span has
// nothing to work with.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/force_layout.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_view.dart';

void main() {
  // A laptop window, not the 800x600 default: the whole defect is about a wide
  // viewport, so testing at the default size would hide it exactly as it hid
  // the off-screen button earlier.
  const desktop = Size(2560, 1430);

  ({double x, double y}) spreadOf(int nodeCount) {
    final ids = [for (var i = 0; i < nodeCount; i++) 'n$i'];
    final layout = ForceLayout(
      nodeIds: ids,
      edges: [for (var i = 1; i < nodeCount; i++) ('n${i - 1}', 'n$i')],
      seed: 3,
    );
    final projected = Brain3dPainter.project(
      nodes: [
        for (final id in ids)
          Brain3dVisualNode(
            id: id,
            label: id,
            color: Colors.teal,
            radius: 6,
          ),
      ],
      positions: layout.positions,
      size: desktop,
      yaw: 0.4,
      pitch: 0.2,
      zoom: 1,
    );
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in projected) {
      minX = p.offset.dx < minX ? p.offset.dx : minX;
      maxX = p.offset.dx > maxX ? p.offset.dx : maxX;
      minY = p.offset.dy < minY ? p.offset.dy : minY;
      maxY = p.offset.dy > maxY ? p.offset.dy : maxY;
    }
    return (x: maxX - minX, y: maxY - minY);
  }

  test('two nodes still use the window', () {
    // THE report. Two dots twenty pixels apart on a 2560-wide screen is not a
    // graph, it is a speck.
    final spread = spreadOf(2);

    expect(spread.x + spread.y, greaterThan(desktop.height * 0.3),
        reason: 'a two-node graph collapsed into a speck');
  });

  test('three nodes use the window', () {
    final spread = spreadOf(3);
    expect(spread.x + spread.y, greaterThan(desktop.height * 0.3));
  });

  test('a busy graph does not overflow it', () {
    // The other side of the same knob: filling the window must not push nodes
    // past its edges, where they are simply invisible.
    final spread = spreadOf(24);

    expect(spread.x, lessThan(desktop.width));
    expect(spread.y, lessThan(desktop.height));
  });

  test('a single node does not divide by zero', () {
    // One memory has no span at all. It must render, not crash.
    expect(() => spreadOf(1), returnsNormally);
  });

  group('a cloud that lies along the camera axis', () {
    // What the laptop screenshot actually showed: one bright dot and one tiny
    // dark one twenty pixels below it. Different SIZES means different depths —
    // the two nodes were separated almost entirely along the camera axis, so
    // they projected on top of each other.
    //
    // No fit can fix that: scaling two points that land in the same place just
    // scales the same place. The camera has to look at the cloud's widest face.

    ({double x, double y}) spreadOfPositions(Map<String, Vec3> positions) {
      final projected = Brain3dPainter.project(
        nodes: [
          for (final id in positions.keys)
            Brain3dVisualNode(id: id, label: id, color: Colors.teal, radius: 6),
        ],
        positions: positions,
        size: desktop,
        yaw: 0,
        pitch: 0,
        zoom: 1,
      );
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in projected) {
        minX = p.offset.dx < minX ? p.offset.dx : minX;
        maxX = p.offset.dx > maxX ? p.offset.dx : maxX;
        minY = p.offset.dy < minY ? p.offset.dy : minY;
        maxY = p.offset.dy > maxY ? p.offset.dy : maxY;
      }
      return (x: maxX - minX, y: maxY - minY);
    }

    test('two nodes apart only in DEPTH are still separated on screen', () {
      final spread = spreadOfPositions({
        'a': const Vec3(0, 0, -12),
        'b': const Vec3(0, 0, 12),
      });

      expect(spread.x + spread.y, greaterThan(desktop.height * 0.3),
          reason: 'they projected on top of each other — the speck on the '
              'laptop');
    });

    test('a flat cloud edge-on is turned to face the viewer', () {
      // Everything in one plane, seen edge-on: a line of dots, unreadable.
      final spread = spreadOfPositions({
        for (var i = 0; i < 6; i++) 'n$i': Vec3(0, i * 4.0 - 10, i * 4.0 - 10),
      });

      expect(spread.x, greaterThan(desktop.width * 0.1),
          reason: 'a plane seen edge-on shows nothing');
    });
  });
}
