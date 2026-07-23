// Proves the /chat routing under on-device-first: local mode is always on, so
// /chat is reachable whether or not the device is paired (it is effectively
// never pairing-gated). Navigating to /chat renders ChatScreen in both cases.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import 'features/local_model/support/fake_local_llm_engine.dart';
import 'support/fake_token_store.dart';

void main() {
  testWidgets('unpaired: /chat is reachable (on-device-first, always local)', (tester) async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
      localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Axi'), findsOneWidget);
  });

  testWidgets('paired: navigating to /chat renders ChatScreen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Axi'), findsOneWidget);
  });
}
