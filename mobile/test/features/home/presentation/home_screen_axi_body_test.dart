// Proves Axi's animated body lives on the HOME screen in BOTH connection
// states (paired and unpaired) — mobile parity of the laptop dashboard's
// living avatar. On the test host no WebView platform is registered, so the
// widget renders its static fallback; what matters here is that HomeScreen
// composes AxiBodyWidget prominently without breaking the existing content.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/axi_body/presentation/axi_body_widget.dart';
import 'package:lifeos/features/home/presentation/home_providers.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../../support/fake_token_store.dart';

GoRouter _router() => GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      ],
    );

Widget _localized(GoRouter router) => MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

void main() {
  testWidgets('unpaired home renders Axi\'s animated body', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_router()),
      ),
    );
    await tester.pump();

    expect(find.byType(AxiBodyWidget), findsOneWidget);
    // On-device-first: the "not connected to an engine" message was removed;
    // the Axi body still renders as the home's on-device content.
    expect(find.text('Aún no está conectado a ningún motor.'), findsNothing);
  });

  testWidgets('paired home renders Axi\'s animated body above the quick nav',
      (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(
          engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: _localized(_router()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(AxiBodyWidget), findsOneWidget);
    // Existing quick nav is intact.
    expect(find.text('Hablar con Axi'), findsOneWidget);
    expect(find.text('Cerebro'), findsOneWidget);
  });
}
