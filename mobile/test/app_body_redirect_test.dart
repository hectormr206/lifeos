// Proves /body is gated behind pairing (spec mobile-app-shell), same
// pattern as /chat and /domains.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/body/data/organs_repository.dart';
import 'package:lifeos/features/body/domain/organ.dart';
import 'package:lifeos/features/body/presentation/organs_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeOrgansRepository implements OrgansRepository {
  @override
  Future<List<OrganState>> list() async => const [];
}

void main() {
  testWidgets('unpaired: navigating to /body redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/body');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /body renders the body screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      organsRepositoryProvider.overrideWithValue(_FakeOrgansRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/body');
    await tester.pumpAndSettle();

    expect(find.text('El cuerpo de Axi'), findsOneWidget);
  });
}
