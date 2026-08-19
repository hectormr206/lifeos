// /reminders is reachable with no engine and no pairing: reminders live in
// the on-device graph and are scheduled on the device. The screen used to
// carry two tabs, "En este dispositivo" and "Desde el motor Axi"; the engine
// is gone, so there is one surface and no tab labels to find.
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
    expect(find.text('Recordatorios'), findsWidgets);
    // And the engine tab is not there to find.
    expect(find.text('Desde el motor Axi'), findsNothing);
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
    expect(find.text('Recordatorios'), findsWidgets);
  });
}
