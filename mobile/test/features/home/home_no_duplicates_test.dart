// The home screen should offer each destination once.
//
// Seen on the test Pixel: "Ajustes" appeared twice — as the icon in the app
// bar and again as a row near the bottom, both going to the same place. Two
// doors into one room is not generosity, it is a moment of doubt for someone
// opening the app for the first time ("are these different?").
//
// Also seen: the row said "Registrar por categoría" and the screen it opened
// was titled "Mis datos". A destination that renames itself on arrival makes
// people wonder whether they tapped the wrong thing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/presentation/domains_hub_screen.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _app(Widget home) => ProviderScope(
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  testWidgets('Ajustes is offered exactly once', (tester) async {
    await tester.pumpWidget(_app(const HomeScreen()));
    await tester.pump();

    // The app-bar icon carries it as a tooltip/semantics label, the row
    // carried it as visible text. One of them had to go, and the icon is the
    // one every screen in the app already has.
    expect(find.text('Ajustes'), findsNothing,
        reason: 'the duplicate row is still there');
  });

  testWidgets('the category screen keeps the name it was opened with',
      (tester) async {
    await tester.pumpWidget(_app(const DomainsHubScreen()));
    await tester.pump();

    expect(find.text('Registrar por categoría'), findsOneWidget);
    expect(find.text('Mis datos'), findsNothing);
  });
}
