// Proves /briefings is gated behind pairing (spec mobile-app-shell), same
// pattern as /chat, /domains, /body, /reminders, /insights.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/briefings/data/briefings_repository.dart';
import 'package:lifeos/features/briefings/domain/briefing.dart';
import 'package:lifeos/features/briefings/presentation/briefings_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeBriefingsRepository implements BriefingsRepository {
  @override
  Future<List<BriefingModel>> list() async => const [];
}

void main() {
  testWidgets('unpaired: navigating to /briefings redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/briefings');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /briefings renders the briefings screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      briefingsRepositoryProvider.overrideWithValue(_FakeBriefingsRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/briefings');
    await tester.pumpAndSettle();

    expect(find.text('Boletines'), findsOneWidget);
  });
}
