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
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../../../features/local_model/support/fake_local_llm_engine.dart';
import '../../../support/fake_token_store.dart';

GoRouter _routerToHome() => GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
        GoRoute(path: '/chat', builder: (context, state) => const Scaffold(body: Text('CHAT'))),
      ],
    );

void main() {
  testWidgets('app-shell: no "Conectar con tu motor" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    // App-shell slice: pairing was removed from the home UI.
    expect(find.text('Conectar con tu motor'), findsNothing);
    expect(find.text('Aún no está conectado a ningún motor.'), findsOneWidget);
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

  testWidgets('hides the "Mis datos" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Mis datos'), findsNothing);
  });

  testWidgets('shows the "Mis datos" CTA when paired', (tester) async {
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

    expect(find.text('Mis datos'), findsOneWidget);
  });

  testWidgets('hides the "visible soul" CTAs (body/reminders/insights) when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('¿Cómo está Axi?'), findsNothing);
    expect(find.text('Recordatorios'), findsNothing);
    expect(find.text('Resumen'), findsNothing);
  });

  testWidgets('shows the "visible soul" CTAs (body/reminders/insights) when paired', (tester) async {
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

    expect(find.text('¿Cómo está Axi?'), findsOneWidget);
    expect(find.text('Recordatorios'), findsOneWidget);
    expect(find.text('Resumen'), findsOneWidget);
  });

  testWidgets('hides the "Axi intelligence" CTAs (boletines/digest) when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Boletines'), findsNothing);
    expect(find.text('Resumen de hoy'), findsNothing);
  });

  testWidgets('shows the "Axi intelligence" CTAs (boletines/digest) when paired', (tester) async {
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

    expect(find.text('Boletines'), findsOneWidget);
    expect(find.text('Resumen de hoy'), findsOneWidget);
  });

  testWidgets('hides the "Ajustes" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Ajustes'), findsNothing);
  });

  testWidgets('shows the "Ajustes" CTA when paired', (tester) async {
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

    expect(find.text('Ajustes'), findsOneWidget);
  });

  testWidgets('hides the "Reuniones" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Reuniones'), findsNothing);
  });

  testWidgets('shows the "Reuniones" CTA when paired', (tester) async {
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

    expect(find.text('Reuniones'), findsOneWidget);
  });

  testWidgets('unpaired + model NOT installed: shows the "Usar modelo local" button, not the chat one',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: false)),
          localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
        ],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Usar modelo local (sin conexión)'), findsOneWidget);
    expect(find.text('Chatear con Axi (sin conexión)'), findsNothing);
  });

  testWidgets('unpaired + model installed: shows the "Chatear con Axi (sin conexión)" button',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
          localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
        ],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chatear con Axi (sin conexión)'), findsOneWidget);
  });

  testWidgets('tapping "Chatear con Axi (sin conexión)" enables local mode and routes to /chat',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
          localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
        ],
        child: MaterialApp.router(routerConfig: _routerToHome()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chatear con Axi (sin conexión)'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.text('CHAT')),
    );
    expect(container.read(localModelEnabledProvider), isTrue);
    expect(find.text('CHAT'), findsOneWidget);
  });
}
