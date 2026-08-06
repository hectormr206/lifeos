// Roadmap slice C2 changed the contract: /reminders is NO LONGER pairing-gated
// (local on-device reminders must work with no engine), so both paired and
// unpaired navigation render the Recordatorios screen with its two tabs.
// (Previously this file asserted the old redirect-to-connection behavior.)
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/reminders/data/reminders_repository.dart';
import 'package:lifeos/features/reminders/domain/reminder.dart';
import 'package:lifeos/features/reminders/presentation/reminders_notifier.dart';

import 'package:lifeos/l10n/locale_providers.dart';

import 'support/fake_token_store.dart';

class _FakeRemindersRepository implements RemindersRepository {
  @override
  Future<List<ReminderModel>> list({String status = 'pending'}) async => const [];

  @override
  Future<void> cancel(String id) async {}
}

Future<void> _pumpAppAndGo(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const LifeOSApp()));
  await tester.pump();
  container.read(goRouterProvider).go('/reminders');
  // Bounded pumps instead of pumpAndSettle: the local tab shows an ongoing
  // loading spinner while the (never-resolving in tests) graph store opens.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('unpaired: /reminders renders the reminders screen (local tab, ungated)', (tester) async {
    final container = ProviderContainer(overrides: [
      // Pin Spanish: the two tab labels are localized now, so an English test
      // host would otherwise render "On this device" and this assertion would
      // be a statement about the CI machine's locale, not about the screen.
      localeProvider.overrideWithValue(const Locale('es')),
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    ]);
    addTearDown(container.dispose);

    await _pumpAppAndGo(tester, container);

    // Scoped to the AppBar: the home route's "Recordatorios" nav button is
    // still mounted during the bounded pumps, and now that the app renders in
    // Spanish here it matches a bare find.text too.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Recordatorios')),
      findsOneWidget,
    );
    expect(find.text('En este dispositivo'), findsOneWidget);
    expect(find.text('Desde el motor Axi'), findsOneWidget);
  });

  testWidgets('paired: /reminders renders the reminders screen', (tester) async {
    final store = FakeTokenStore(
      const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
    );
    final container = ProviderContainer(overrides: [
      localeProvider.overrideWithValue(const Locale('es')),
      tokenStoreProvider.overrideWithValue(store),
      remindersRepositoryProvider.overrideWithValue(_FakeRemindersRepository()),
    ]);
    addTearDown(container.dispose);

    await _pumpAppAndGo(tester, container);

    // Scoped to the AppBar: the home route's "Recordatorios" nav button is
    // still mounted during the bounded pumps, and now that the app renders in
    // Spanish here it matches a bare find.text too.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Recordatorios')),
      findsOneWidget,
    );
    expect(find.text('En este dispositivo'), findsOneWidget);
  });
}
