// The way out has to be findable.
//
// An export nobody can find is the same as no export: the promise "tu vida, tu
// máquina" is only true if the user can act on it without being told where to
// click.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

void main() {
  testWidgets('Ajustes offers a way to take your data out', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsHubScreen(),
      ),
    ));
    await tester.pump();

    final tile = find.text('Llévate tus datos');
    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);

    expect(tile, findsOneWidget);
  });

  testWidgets('it says what it is FOR, not what format it uses',
      (tester) async {
    // "Exportar JSON" means nothing to the person this exists to protect.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsHubScreen(),
      ),
    ));
    await tester.pump();

    final tile = find.textContaining('aunque un día no uses LifeOS');
    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);

    expect(tile, findsOneWidget);
  });
}
