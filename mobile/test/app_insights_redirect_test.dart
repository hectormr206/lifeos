// Proves /insights is gated behind pairing (spec mobile-app-shell), same
// pattern as /chat and /domains.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/insights/data/insights_repository.dart';
import 'package:lifeos/features/insights/domain/digest.dart';
import 'package:lifeos/features/insights/presentation/insights_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeInsightsRepository implements InsightsRepository {
  @override
  Future<DigestModel> preview({String cadence = 'daily'}) async => DigestModel(
        cadence: cadence,
        body: '',
        sectionsCount: 0,
        patternsCount: 0,
        correlationsCount: 0,
        generatedAt: DateTime.now(),
      );
}

void main() {
  testWidgets('unpaired: navigating to /insights redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/insights');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /insights renders the insights screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      insightsRepositoryProvider.overrideWithValue(_FakeInsightsRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/insights');
    await tester.pumpAndSettle();

    expect(find.text('Resumen'), findsOneWidget);
  });
}
