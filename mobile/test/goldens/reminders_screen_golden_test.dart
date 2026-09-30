import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_notifier.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:lifeos/features/reminders/presentation/reminders_screen.dart';

import 'support/golden_harness.dart';

// Same synchronous state-override pattern as the Mi vida golden; no DB or
// notification plugins. Pending, recurring, fired and disabled rows are visible.
class _FixedReminders extends LocalRemindersNotifier {
  @override
  LocalRemindersUiState build() => LocalRemindersUiState(loading: false, reminders: [
    LocalReminder(uuid: '1', text: 'Llamar al doctor', dueAt: DateTime(2026, 9, 25, 9, 30)),
    LocalReminder(uuid: '2', text: 'Inglés: tu práctica de hoy', dueAt: DateTime(2026, 9, 25, 17, 43), recurrence: ReminderRecurrence.daily),
    LocalReminder(uuid: '3', text: 'Comprar pan', dueAt: DateTime(2026, 9, 25, 7), status: LocalReminderStatus.fired),
    LocalReminder(uuid: '4', text: 'Tomar vitaminas', dueAt: DateTime(2026, 9, 25, 8), recurrence: ReminderRecurrence.daily, status: LocalReminderStatus.disabled),
  ]);
  @override
  Future<void> refresh() async {}
}

class _Clock implements Clock {
  @override
  DateTime now() => DateTime(2026, 9, 25, 8);
}

class _Scheduler implements ReminderScheduler {
  @override
  Future<void> schedule(LocalReminder reminder) async {}
  @override
  Future<void> cancel(LocalReminder reminder) async {}
}

void main() {
  testWidgets('golden: local reminder states and composer', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(ProviderScope(overrides: [
      clockProvider.overrideWithValue(_Clock()),
      localRemindersNotifierProvider.overrideWith(_FixedReminders.new),
      reminderSchedulerProvider.overrideWithValue(_Scheduler()),
    ], child: MaterialApp(theme: goldenTheme(), home: const RemindersScreen())));
    await tester.pumpAndSettle();
    await expectLater(find.byType(RemindersScreen),
        matchesGoldenFile('images/reminders_screen.png'));
  });
}
