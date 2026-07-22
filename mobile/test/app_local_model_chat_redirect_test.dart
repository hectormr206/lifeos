// Proves the roadmap SLICE 1 routing amendment (safe + additive): with the
// on-device toggle ON, an UNPAIRED device can reach /chat; with the toggle OFF
// the pre-existing paired-only gate is UNCHANGED (unpaired still redirects to
// the connection screen). Overrides the local engine + prefs with fakes so no
// flutter_gemma / shared_preferences channel is touched.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import 'features/local_model/support/fake_local_llm_engine.dart';
import 'support/fake_token_store.dart';

ProviderContainer _unpairedContainer() {
  final container = ProviderContainer(overrides: [
    tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    // Installed so local mode can actually be enabled (the toggle + notifier
    // now gate turning it on until the weights are present).
    localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
    localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('local model ON + unpaired: /chat is reachable', (tester) async {
    final container = _unpairedContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    // Turn on on-device mode, then navigate.
    await container.read(localModelEnabledProvider.notifier).setEnabled(true);
    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Axi'), findsOneWidget);
  });

  testWidgets('local model OFF + unpaired: /chat still redirects to connection', (tester) async {
    final container = _unpairedContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });
}
