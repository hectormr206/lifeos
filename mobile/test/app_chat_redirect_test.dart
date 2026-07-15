// Proves the /chat route is gated behind pairing (spec mobile-app-shell,
// M1 slice 2): navigating to /chat while unpaired redirects to the
// connection screen; navigating to /chat while paired renders ChatScreen.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';

import 'support/fake_token_store.dart';

void main() {
  testWidgets('unpaired: navigating to /chat redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    container.read(goRouterProvider).go('/chat');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /chat renders ChatScreen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
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
