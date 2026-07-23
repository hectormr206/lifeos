// Proves LocalRemindersNotifier's lifecycle (roadmap slice C2): initial load
// re-arms pending alarms, create schedules with the parsed instant (device
// clock via clockProvider), recurrence flows through, complete/remove cancel
// the alarm, and a broken store surfaces an error instead of throwing. Store
// is the REAL SQL over ffi; the scheduler is a fake — no platform channels.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/reminders/data/local_reminders_repository.dart';
import 'package:lifeos/features/reminders/data/local_reminders_service.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_notifier.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime now() => value;
}

class _RecordingScheduler implements ReminderScheduler {
  final List<LocalReminder> scheduled = [];
  final List<LocalReminder> cancelled = [];

  @override
  Future<void> schedule(LocalReminder reminder) async => scheduled.add(reminder);

  @override
  Future<void> cancel(LocalReminder reminder) async => cancelled.add(reminder);
}

void main() {
  // Wednesday 2026-07-22 10:00.
  final now = DateTime(2026, 7, 22, 10);
  late Database db;
  late _RecordingScheduler scheduler;
  late ProviderContainer container;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    scheduler = _RecordingScheduler();
    final service = LocalRemindersService(
      LocalRemindersRepository(SqfliteLocalGraphStore(db)),
      scheduler,
    );
    container = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(_FixedClock(now)),
      localRemindersServiceProvider.overrideWith((ref) async => service),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('NL create schedules the notification at the parsed instant', () async {
    final notifier = container.read(localRemindersNotifierProvider.notifier);
    await notifier.ready;

    final parsed = notifier.parse('recuérdame llamar al doctor mañana a las 8')!;
    await notifier.create(
      text: parsed.text,
      dueAt: parsed.dueAt!,
      recurrence: parsed.recurrence,
    );

    expect(scheduler.scheduled, hasLength(1));
    final armed = scheduler.scheduled.single;
    expect(armed.dueAt, DateTime(2026, 7, 23, 8)); // right time, device clock
    expect(armed.text, 'llamar al doctor');
    expect(armed.recurrence, ReminderRecurrence.none);

    final state = container.read(localRemindersNotifierProvider);
    expect(state.loading, isFalse);
    expect(state.reminders.single.text, 'llamar al doctor');
  });

  test('daily recurrence flows from parse to the scheduled reminder', () async {
    final notifier = container.read(localRemindersNotifierProvider.notifier);
    await notifier.ready;

    final parsed =
        notifier.parse('recuérdame tomar la medicina todos los días a las 7')!;
    await notifier.create(
      text: parsed.text,
      dueAt: parsed.dueAt!,
      recurrence: parsed.recurrence,
    );

    final armed = scheduler.scheduled.single;
    expect(armed.recurrence, ReminderRecurrence.daily);
    expect(armed.dueAt, DateTime(2026, 7, 23, 7)); // 07:00 already passed → next
  });

  test('unparseable time yields dueAt null so the UI asks for one', () async {
    final notifier = container.read(localRemindersNotifierProvider.notifier);
    await notifier.ready;

    final parsed = notifier.parse('recuérdame llamar a Ana')!;
    expect(parsed.dueAt, isNull);
    expect(scheduler.scheduled, isEmpty); // nothing scheduled without a time
  });

  test('complete and remove cancel the alarm and refresh the list', () async {
    final notifier = container.read(localRemindersNotifierProvider.notifier);
    await notifier.ready;
    await notifier.create(text: 'uno', dueAt: DateTime(2026, 7, 23, 9));
    await notifier.create(text: 'dos', dueAt: DateTime(2026, 7, 24, 9));
    final reminders = container.read(localRemindersNotifierProvider).reminders;

    await notifier.complete(reminders[0]);
    await notifier.remove(reminders[1]);

    expect(scheduler.cancelled.map((r) => r.text).toSet(), {'uno', 'dos'});
    expect(container.read(localRemindersNotifierProvider).reminders, isEmpty);
  });

  test('a broken store degrades to an error state, never a throw', () async {
    final broken = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(_FixedClock(now)),
      localRemindersServiceProvider
          .overrideWith((ref) => throw StateError('no store')),
    ]);
    addTearDown(broken.dispose);

    final notifier = broken.read(localRemindersNotifierProvider.notifier);
    await notifier.ready;

    final state = broken.read(localRemindersNotifierProvider);
    expect(state.loading, isFalse);
    expect(state.error, isNotNull);
  });
}
