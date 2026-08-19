// The reminders screen — a single LOCAL surface.
//
// The engine-viewer tests that used to live here went with the tab they
// covered: reminders on a paired server are not a thing any more, because
// every device runs its own model and the graph syncs the results. What is
// left is this device's own composer and list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/reminders/presentation/reminders_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _localizedApp() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RemindersScreen(),
      ),
    );

/// The local tab keeps a progress indicator running while it loads, so
/// `pumpAndSettle` would wait for an animation that is the point of the
/// screen.
Future<void> _settleEnough(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('the create button is dead until there is something to create',
      (tester) async {
    // Seen on the test Pixel: with the box empty, tapping the alarm icon did
    // absolutely nothing — no form, no message, no hint. The handler returned
    // early on empty text while the button still looked and behaved like a
    // live control, so the only thing the app communicated was that it was
    // broken. A disabled button says "not yet" by being grey.
    await tester.pumpWidget(_localizedApp());
    await _settleEnough(tester);

    final button = find.widgetWithIcon(IconButton, Icons.alarm_add);
    expect(tester.widget<IconButton>(button).onPressed, isNull,
        reason: 'an empty box offers nothing to create');

    await tester.enterText(find.byType(TextField).first, 'comprar pan');
    await tester.pump();

    expect(tester.widget<IconButton>(button).onPressed, isNotNull,
        reason: 'with text typed the button must come alive');
  });

  testWidgets('whitespace alone does not count as text', (tester) async {
    await tester.pumpWidget(_localizedApp());
    await _settleEnough(tester);

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();

    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.alarm_add))
          .onPressed,
      isNull,
    );
  });
}
