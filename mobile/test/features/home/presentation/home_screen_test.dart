// Proves HomeScreen renders the right view for each connection state
// (spec mobile-app-shell): the "connect" CTA when unpaired, the connected
// view (engine URL + reachability indicator) when paired. Overrides
// tokenStoreProvider (drives ConnectionNotifier's bootstrap) and
// engineReachableProvider (avoids a real HTTP call) — no live engine.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/home/presentation/home_providers.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';

import '../../../support/fake_token_store.dart';

GoRouter _routerToHome() => GoRouter(
      routes: [GoRoute(path: '/', builder: (context, state) => const HomeScreen())],
    );

void main() {
  testWidgets('shows the connect CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Conectar con tu motor'), findsOneWidget);
  });

  testWidgets('shows the connected view with a reachable indicator when paired', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Conectado a https://10.66.66.2:8081'), findsOneWidget);
    expect(find.text('Motor accesible'), findsOneWidget);
  });

  testWidgets('hides the "Hablar con Axi" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Hablar con Axi'), findsNothing);
  });

  testWidgets('shows the "Hablar con Axi" CTA when paired', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Hablar con Axi'), findsOneWidget);
  });
}
