// Reminders is ONE surface now: this device.
//
// The second tab, "Desde el motor Axi", was a viewer for reminders living on a
// paired server. That design is gone: the plan was to run a bigger model on a
// powerful machine and share it, and today every device runs its own local
// model. Nothing is on the other side of that tab, so it could only ever show
// "No se pudo conectar con Axi. Revisa tu conexión" — sending someone to check
// a Wi-Fi that was never the problem.
//
// Offering a control that cannot work is worse than not offering it: it costs
// the user the time to try, and it teaches them the app is unreliable.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/reminders/presentation/reminders_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _app() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RemindersScreen(),
      ),
    );

void main() {
  testWidgets('there are no tabs at all', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsNothing);
  });

  testWidgets('the engine is never mentioned', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.textContaining('motor'), findsNothing);
    // And no "En este dispositivo" either: that label only ever existed to
    // distinguish this surface from the engine one. With nothing to contrast
    // against, it is noise.
    expect(find.textContaining('En este dispositivo'), findsNothing);
  });

  testWidgets('the local composer is reachable straight away', (tester) async {
    // It used to be behind whichever tab happened to be selected.
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
  });
}
