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
import 'package:lifeos/l10n/app_localizations.dart';

import '../../../features/local_model/support/fake_local_llm_engine.dart';
import '../../../support/fake_token_store.dart';

GoRouter _routerToHome() => GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
        GoRoute(path: '/chat', builder: (context, state) => const Scaffold(body: Text('CHAT'))),
        GoRoute(path: '/mi-vida', builder: (context, state) => const Scaffold(body: Text('MI VIDA'))),
        GoRoute(path: '/domains', builder: (context, state) => const Scaffold(body: Text('DOMAINS'))),
        GoRoute(path: '/reminders', builder: (context, state) => const Scaffold(body: Text('REMINDERS'))),
        GoRoute(path: '/settings', builder: (context, state) => const Scaffold(body: Text('SETTINGS'))),
      ],
    );

/// Wraps the router in a Spanish-localized MaterialApp so the localized
/// HomeScreen renders its es strings deterministically (the test host's device
/// locale would otherwise resolve to English).
Widget _localized(GoRouter router) => MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Axi's avatar animates forever, so a tree containing it NEVER settles
      // and pumpAndSettle times out. These tests are about routing and copy,
      // not about the mascot: disableAnimations is the same flag the widget
      // already honours for prefers-reduced-motion, so it stops the loop
      // through the real code path rather than through a test-only stub.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );

void main() {
  testWidgets('app-shell: no "Conectar con tu motor" CTA when unpaired', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    // App-shell slice: pairing was removed from the home UI.
    expect(find.text('Conectar con tu motor'), findsNothing);
    // On-device-first: the "not connected to an engine" message was removed.
    expect(find.text('Aún no está conectado a ningún motor.'), findsNothing);
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
        child: _localized(_routerToHome()),
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
        child: _localized(_routerToHome()),
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
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Hablar con Axi'), findsOneWidget);
  });

  testWidgets(
      'on-device (unpaired): shows the full grouped menu — four section headers + both record entries',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    // All four section headers render on the on-device home now.
    expect(find.text('Tus registros'), findsOneWidget);
    expect(find.text('Axi'), findsOneWidget);
    expect(find.text('Avisos y resúmenes'), findsOneWidget);
    expect(find.text('Ajustes y sistema'), findsOneWidget);

    // Both record entries with their subtitles.
    expect(find.text('Mi vida'), findsOneWidget);
    expect(find.text('Todo lo que registras, por persona'), findsOneWidget);
    expect(find.text('Registrar por categoría'), findsOneWidget);
    expect(find.text('Salud, finanzas, ejercicio, relaciones…'), findsOneWidget);
    // The old flat label is gone.
    expect(find.text('Mis datos'), findsNothing);
  });

  testWidgets('shows the grouped "Tus registros" section with both record entries when paired',
      (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Section headers render, grouping the flat list.
    expect(find.text('Tus registros'), findsOneWidget);
    expect(find.text('Axi'), findsOneWidget);
    expect(find.text('Avisos y resúmenes'), findsOneWidget);
    expect(find.text('Ajustes y sistema'), findsOneWidget);

    // Both record entries are present with their clarifying subtitles.
    expect(find.text('Mi vida'), findsOneWidget);
    expect(find.text('Todo lo que registras, por persona'), findsOneWidget);
    expect(find.text('Registrar por categoría'), findsOneWidget);
    expect(find.text('Salud, finanzas, ejercicio, relaciones…'), findsOneWidget);
    // The old flat label is gone.
    expect(find.text('Mis datos'), findsNothing);
  });

  testWidgets('tapping "Mi vida" navigates to /mi-vida', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.text('Mi vida'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mi vida'));
    await tester.pumpAndSettle();

    expect(find.text('MI VIDA'), findsOneWidget);
  });

  testWidgets('tapping "Registrar por categoría" navigates to /domains', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          engineReachableProvider.overrideWith((ref) async => true),
        ],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.text('Registrar por categoría'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Registrar por categoría'));
    await tester.pumpAndSettle();

    expect(find.text('DOMAINS'), findsOneWidget);
  });

  testWidgets('on-device (unpaired): shows the "visible soul" CTAs (body/reminders/insights)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('¿Cómo está Axi?'), findsOneWidget);
    expect(find.text('Recordatorios'), findsOneWidget);
    expect(find.text('Resumen'), findsOneWidget);
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
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('¿Cómo está Axi?'), findsOneWidget);
    expect(find.text('Recordatorios'), findsOneWidget);
    expect(find.text('Resumen'), findsOneWidget);
  });

  testWidgets('on-device (unpaired): shows the "Axi intelligence" CTAs (boletines/digest)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Boletines'), findsOneWidget);
    expect(find.text('Resumen de hoy'), findsOneWidget);
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
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Boletines'), findsOneWidget);
    expect(find.text('Resumen de hoy'), findsOneWidget);
  });

  testWidgets('on-device (unpaired): shows the "Ajustes" CTA', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Ajustes'), findsOneWidget);
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
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Ajustes'), findsOneWidget);
  });

  testWidgets('on-device (unpaired): shows the "Reuniones" CTA', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: _localized(_routerToHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Reuniones'), findsOneWidget);
  });

  testWidgets('on-device (unpaired): key routes are reachable from the grouped menu',
      (tester) async {
    // "Mi vida" (records), "Registrar por categoría" (/domains),
    // "Recordatorios" (/reminders) and "Ajustes" (/settings) all navigate.
    for (final entry in const [
      ('Mi vida', 'MI VIDA'),
      ('Registrar por categoría', 'DOMAINS'),
      ('Recordatorios', 'REMINDERS'),
      ('Ajustes', 'SETTINGS'),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
          child: _localized(_routerToHome()),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(find.text(entry.$1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.$1));
      await tester.pumpAndSettle();

      expect(find.text(entry.$2), findsOneWidget, reason: 'route for ${entry.$1}');
    }
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
        child: _localized(_routerToHome()),
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
        child: _localized(_routerToHome()),
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
        child: _localized(_routerToHome()),
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
        child: _localized(_routerToHome()),
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
