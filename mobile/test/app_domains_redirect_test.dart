// Proves /domains and /domains/:key are gated behind pairing (spec
// mobile-app-shell), same pattern as /chat (see app_chat_redirect_test.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/domains/data/domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/domain/domain_entry.dart';
import 'package:lifeos/features/domains/presentation/domain_notifier.dart';

import 'support/fake_token_store.dart';

/// Avoids a real (unreachable-host) network call for the domain list: unlike
/// chat's history load, `DomainListScreen` shows a persistent (animating)
/// loading spinner while `state.loading` is true, which would otherwise
/// starve `pumpAndSettle` waiting on a real DioException to resolve.
class _FakeDomainRepository implements DomainRepository {
  @override
  Future<List<DomainEntry>> list(DomainDescriptor descriptor) async => const [];
}

void main() {
  testWidgets('unpaired: navigating to /domains redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/domains');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /domains renders the domains hub', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/domains');
    await tester.pumpAndSettle();

    expect(find.text('Mis datos'), findsOneWidget);
  });

  testWidgets('paired: navigating to /domains/health renders the health domain list', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      domainRepositoryProvider.overrideWithValue(_FakeDomainRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/domains/health');
    await tester.pumpAndSettle();

    expect(find.text('Salud'), findsOneWidget);
  });
}
