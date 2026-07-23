// Roadmap "native domain CRUD" slice changed the contract: /domains is NO
// LONGER pairing-gated — the local "En este teléfono" CRUD tab must work with
// no engine, so both paired and unpaired navigation render the domains UI.
// (Previously this file asserted redirect-to-connection when unpaired.)
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

class _FakeDomainRepository implements DomainRepository {
  @override
  Future<List<DomainEntry>> list(DomainDescriptor descriptor) async => const [];

  @override
  Future<DomainEntry> createEntry(DomainDescriptor descriptor, Map<String, Object?> body) async =>
      DomainEntry(id: 'x', title: body['title'] as String? ?? '', timestamp: DateTime.now());
}

Future<void> _pumpAppAndGo(WidgetTester tester, ProviderContainer container, String location) async {
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
  await tester.pump();
  container.read(goRouterProvider).go(location);
  // Bounded pumps, not pumpAndSettle: the local domain tab shows an ongoing
  // spinner while the (never-resolving in tests) graph store opens.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('unpaired: /domains renders the hub (ungated)', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);

    await _pumpAppAndGo(tester, container, '/domains');

    expect(find.text('Mis datos'), findsOneWidget);
  });

  testWidgets('paired: /domains renders the domains hub', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);

    await _pumpAppAndGo(tester, container, '/domains');

    expect(find.text('Mis datos'), findsOneWidget);
  });

  testWidgets('/domains/health renders the health domain screen (local tab, ungated)', (tester) async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
      domainRepositoryProvider.overrideWithValue(_FakeDomainRepository()),
    ]);
    addTearDown(container.dispose);

    await _pumpAppAndGo(tester, container, '/domains/health');

    expect(find.text('Salud'), findsOneWidget);
  });
}
