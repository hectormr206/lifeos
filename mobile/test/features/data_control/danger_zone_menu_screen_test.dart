// Proves the "Zona de peligro" MENU screen lists the wipe action and pushes the
// existing typed-confirmation ceremony (the ceremony itself is unchanged).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/data_control/presentation/danger_zone_menu_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

GoRouter _router() => GoRouter(
      initialLocation: '/settings/danger-zone',
      routes: [
        GoRoute(
            path: '/settings/danger-zone', builder: (c, s) => const DangerZoneMenuScreen()),
        GoRoute(path: '/settings/danger', builder: (c, s) => const Scaffold(body: Text('WIPE'))),
      ],
    );

Widget _app() => MaterialApp.router(
      routerConfig: _router(),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

void main() {
  testWidgets('lists "Borrar todos mis datos" and pushes the wipe ceremony', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Zona de peligro'), findsOneWidget); // AppBar title
    expect(find.text('Borrar todos mis datos'), findsOneWidget);

    await tester.tap(find.text('Borrar todos mis datos'));
    await tester.pumpAndSettle();

    expect(find.text('WIPE'), findsOneWidget);
  });
}
