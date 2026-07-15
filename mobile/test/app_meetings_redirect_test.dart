// Proves /meetings (and /meetings/:id) is gated behind pairing (spec
// mobile-app-shell), same pattern as /chat, /domains, /graph.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/meetings/data/meetings_repository.dart';
import 'package:lifeos/features/meetings/domain/meeting.dart';
import 'package:lifeos/features/meetings/domain/meeting_detail.dart';
import 'package:lifeos/features/meetings/presentation/meetings_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeMeetingsRepository implements MeetingsRepository {
  @override
  Future<List<MeetingModel>> list() async => const [];

  @override
  Future<MeetingDetail> detail(int id) => throw UnimplementedError();
}

void main() {
  testWidgets('unpaired: navigating to /meetings redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/meetings');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /meetings renders the meetings screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      meetingsRepositoryProvider.overrideWithValue(_FakeMeetingsRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/meetings');
    await tester.pumpAndSettle();

    expect(find.text('Reuniones'), findsOneWidget);
  });
}
