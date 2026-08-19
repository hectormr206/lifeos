// /chat needs no pairing: the model runs on the device.
//
// The other half of this file asserted that an engine-only route still
// redirected to the connection screen. There are no engine-only routes any
// more, and no connection screen to redirect to.
// UNPAIRED device can always reach /chat (it is effectively never pairing-
// gated). The pairing gate itself is UNCHANGED for the other engine-only
// routes — an unpaired device still redirects those to the connection screen,
// so pairing stays wired for Phase D. Overrides the local engine with a fake so
// no flutter_gemma channel is touched.
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
    localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('local mode always on + unpaired: /chat is reachable', (tester) async {
    final container = _unpairedContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Axi'), findsOneWidget);
  });
}
