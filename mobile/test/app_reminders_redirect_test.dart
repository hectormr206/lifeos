// Proves /reminders is gated behind pairing (spec mobile-app-shell), same
// pattern as /chat and /domains.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/reminders/data/reminders_repository.dart';
import 'package:lifeos/features/reminders/domain/reminder.dart';
import 'package:lifeos/features/reminders/presentation/reminders_notifier.dart';

import 'support/fake_token_store.dart';

class _FakeRemindersRepository implements RemindersRepository {
  @override
  Future<List<ReminderModel>> list({String status = 'pending'}) async => const [];

  @override
  Future<void> cancel(String id) async {}
}

void main() {
  testWidgets('unpaired: navigating to /reminders redirects to the connection screen', (tester) async {
    final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();

    container.read(goRouterProvider).go('/reminders');
    await tester.pumpAndSettle();

    expect(find.text('Conexión'), findsOneWidget);
  });

  testWidgets('paired: navigating to /reminders renders the reminders screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      remindersRepositoryProvider.overrideWithValue(_FakeRemindersRepository()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
    await tester.pump();
    await tester.pump();

    container.read(goRouterProvider).go('/reminders');
    await tester.pumpAndSettle();

    expect(find.text('Recordatorios'), findsOneWidget);
  });
}
