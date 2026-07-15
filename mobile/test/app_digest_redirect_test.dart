// Proves /digest is gated behind pairing (spec mobile-app-shell), same
// pattern as /chat, /domains, /body, /reminders, /insights, /briefings.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/digest/data/digest_repository.dart';
import 'package:lifeos/features/digest/domain/today_digest.dart';
import 'package:lifeos/features/digest/presentation/digest_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeDigestRepository implements DigestRepository {
  @override
  Future<TodayDigest> today() async => const TodayDigest(
        date: '2026-07-14',
        conversationsCount: 0,
        meetingsCount: 0,
        factsAddedCount: 0,
        eventsCriticalCount: 0,
        eventsErrorCount: 0,
      );
}

void main() {
  testWidgets('unpaired: navigating to /digest redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/digest');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /digest renders the digest screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      digestRepositoryProvider.overrideWithValue(_FakeDigestRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/digest');
    await tester.pumpAndSettle();

    expect(find.text('Resumen de hoy'), findsOneWidget);
  });
}
