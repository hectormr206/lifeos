// Zooming with a mouse wheel, because half the devices running this have one.
//
// Reported from the laptop: the hint says "Zoom: pellizcar" and there is
// nothing to pinch. Pinch-to-zoom is a touch gesture; on a desktop the same
// intention is a scroll wheel, and without it the graph simply cannot be
// zoomed at all on Linux — a control that exists on the phone and is missing
// on the laptop, which is the split this codebase keeps trying to avoid.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_view.dart';

void main() {
  Widget app() => MaterialApp(
        home: Scaffold(
          body: Brain3dView(
            nodes: const [
              Brain3dVisualNode(id: 'a', label: 'a', color: Colors.teal),
              Brain3dVisualNode(id: 'b', label: 'b', color: Colors.teal),
              Brain3dVisualNode(id: 'c', label: 'c', color: Colors.teal),
            ],
            edges: const [('a', 'b'), ('b', 'c')],
          ),
        ),
      );

  /// The zoom the painter was last given — the only honest way to ask "did the
  /// view zoom", since the field itself is private.
  double paintedZoom(WidgetTester tester) {
    final paint = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((p) => p.painter is Brain3dPainter);
    return (paint.painter! as Brain3dPainter).zoom;
  }

  Future<void> scroll(WidgetTester tester, double dy) async {
    final centre = tester.getCenter(find.byType(Brain3dView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('scrolling up zooms in', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final before = paintedZoom(tester);

    await scroll(tester, -120);

    expect(paintedZoom(tester), greaterThan(before));
  });

  testWidgets('scrolling down zooms out', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final before = paintedZoom(tester);

    await scroll(tester, 120);

    expect(paintedZoom(tester), lessThan(before));
  });

  testWidgets('the wheel obeys the same limits as the pinch', (tester) async {
    // Without the clamp a few flicks of the wheel put every node behind the
    // camera or in a single pixel, and there is no way back except leaving the
    // screen.
    await tester.pumpWidget(app());
    await tester.pump();

    for (var i = 0; i < 40; i++) {
      await scroll(tester, -120);
    }
    expect(paintedZoom(tester), lessThanOrEqualTo(4.0));

    for (var i = 0; i < 80; i++) {
      await scroll(tester, 120);
    }
    expect(paintedZoom(tester), greaterThanOrEqualTo(0.4));
  });
}
