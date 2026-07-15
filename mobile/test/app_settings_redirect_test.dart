// Proves /settings (the engine config editor, laptop /config parity) is
// gated behind pairing (spec mobile-app-shell), same pattern as /chat,
// /domains, /body, /reminders, /insights, /briefings, /digest. NOTE: this is
// distinct from the pre-existing `/settings/connection` route (pairing
// setup) — `/settings` is the config-editing screen added this batch.
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
  testWidgets('unpaired: navigating to /settings redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/settings');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /settings renders the settings screen', (tester) async {
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

    container.read(goRouterProvider).go('/settings');
    await tester.pumpAndSettle();

    expect(find.text('Ajustes'), findsOneWidget);
  });
}
