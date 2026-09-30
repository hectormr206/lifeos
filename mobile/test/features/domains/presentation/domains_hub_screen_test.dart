// Every registered domain stays discoverable in the shared navigation group.
// The registry still owns labels, icons and destinations.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/presentation/domains_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';

void main() {
  testWidgets('domain navigation is grouped and constrained on desktop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DomainsHubScreen(),
    ));
    await tester.pump();
    expect(find.byType(GroupedRow), findsNWidgets(domainDescriptors.length));
    expect(tester.getSize(find.byType(GroupedList)).width, lessThanOrEqualTo(kContentMaxWidth - 2 * kPageGutter));
  });

  testWidgets('every grouped domain row keeps its registered destination', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const DomainsHubScreen()),
      GoRoute(path: '/domains/:key', builder: (_, state) => Scaffold(body: Text('Opened ${state.pathParameters['key']}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    await tester.pumpAndSettle();
    for (final descriptor in domainDescriptors) {
      await tester.tap(find.text(descriptor.title));
      await tester.pumpAndSettle();
      expect(find.text('Opened ${descriptor.key}'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('shows a row for each registered domain', (tester) async {
    // A tall surface makes every registered destination visible at once.
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
