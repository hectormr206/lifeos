import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/presentation/domains_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'support/golden_harness.dart';

void main() {
  testWidgets('golden: registered domain navigation', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(MaterialApp(
      theme: goldenTheme(),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const DomainsHubScreen(),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(DomainsHubScreen),
        matchesGoldenFile('images/domains_hub.png'));
  });
}
