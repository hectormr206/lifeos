// Proves the domains hub (spec mobile-domain-crud / mobile-app-shell) shows
// a card for each registered domain — all 7 as of M2 slice 2 (health,
// finance, exercise, relationships, spirituality, learning, calendar); the
// grid grew from 3 to 7 cards purely by extending domainDescriptors, zero
// changes to DomainsHubScreen itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/presentation/domains_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

void main() {
  testWidgets('shows a card for each registered domain', (tester) async {
    // A GridView is lazy: with 7 cards (up from 3), the later ones aren't
    // built until scrolled into view. A tall surface makes all 7 fit without
    // scrolling, same assertion style as before scale exposed this.
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Localized: the title now comes from the same string the home row uses,
    // so the screen needs the delegates to build at all.
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DomainsHubScreen(),
    ));
    await tester.pump();

    for (final descriptor in domainDescriptors) {
      expect(find.text(descriptor.title), findsOneWidget);
    }
  });
}
