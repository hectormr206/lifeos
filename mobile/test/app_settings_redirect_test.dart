// App-shell slice routing:
//   * `/settings` is the offline-reachable Settings HUB (appearance, model,
//     updates, about) — NOT pairing-gated.
//   * `/settings/engine` is the engine config editor (laptop /config parity),
//     relocated from `/settings` and still pairing-gated.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/settings/data/settings_repository.dart';
import 'package:lifeos/features/settings/domain/config_field_descriptor.dart';
import 'package:lifeos/features/settings/presentation/settings_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<List<ConfigFieldDescriptor>> fetchConfig() async => const [];

  @override
  Future<List<ConfigFieldDescriptor>> updateConfig(Map<String, Object?> changes) async => const [];
}

void main() {
  testWidgets('unpaired: /settings renders the hub (not gated)', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/settings');
    await tester.pumpAndSettle();

    // Hub is reachable offline: shows the appearance section, no redirect.
    expect(find.text('Apariencia'), findsOneWidget);
    expect(find.text('Conexión'), findsNothing);
  });

  testWidgets('unpaired: /settings/engine redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/settings/engine');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: /settings/engine renders the engine config editor', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/settings/engine');
    await tester.pumpAndSettle();

    // The config editor (empty fake schema) — distinct from the hub.
    expect(find.text('No hay campos de configuración disponibles.'), findsOneWidget);
  });
}
