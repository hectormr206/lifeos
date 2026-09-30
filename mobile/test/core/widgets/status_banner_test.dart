import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/widgets/status_banner.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, String text) => tester.pumpWidget(MaterialApp(
        theme: lifeosLightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 220,
            child: StatusBanner(
              tone: BannerTone.info,
              icon: Icons.info_outline,
              message: Text(text, key: const Key('msg')),
            ),
          ),
        ),
      ));

  testWidgets('icon aligns with the first line of a multi-line message', (tester) async {
    await pump(tester, 'This message is long enough that it wraps across several lines. ' * 3);
    final text = tester.getRect(find.byKey(const Key('msg')));
    expect(text.height, greaterThan(22 * 3));
    final icon = tester.getRect(find.byIcon(Icons.info_outline));
    const firstLineHeight = 22.0;
    final firstLineCenter = text.top + firstLineHeight / 2;
    expect(icon.center.dy, closeTo(firstLineCenter, 2));
  });

  testWidgets('icon stays centred on a single-line message', (tester) async {
    await pump(tester, 'Short');
    final text = tester.getRect(find.byKey(const Key('msg')));
    final icon = tester.getRect(find.byIcon(Icons.info_outline));
    expect(icon.center.dy, closeTo(text.center.dy, 2));
  });
}
