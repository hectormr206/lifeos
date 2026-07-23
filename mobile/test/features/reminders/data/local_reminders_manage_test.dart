// Proves the LOCAL reminders management added this slice: DEACTIVATE keeps the
// row but cancels the scheduled notification (and re-enable reschedules it), and
// EDIT changes content + re-arms the alarm at the new instant. Store is the REAL
// SQL over ffi; the scheduler is a recording fake — no platform channels.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/reminders/data/local_reminders_repository.dart';
import 'package:lifeos/features/reminders/data/local_reminders_service.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingScheduler implements ReminderScheduler {
  final List<LocalReminder> scheduled = [];
  final List<LocalReminder> cancelled = [];
  @override
  Future<void> schedule(LocalReminder reminder) async => scheduled.add(reminder);
  @override
  Future<void> cancel(LocalReminder reminder) async => cancelled.add(reminder);
}

void main() {
  setUpAll(sqfliteFfiInit);

  final now = DateTime(2026, 7, 22, 10);
  late Database db;
  late _RecordingScheduler scheduler;
  late LocalRemindersService service;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    scheduler = _RecordingScheduler();
    service = LocalRemindersService(
      LocalRemindersRepository(SqfliteLocalGraphStore(db)),
      scheduler,
    );
  });

  tearDown(() async => db.close());

  test('deactivate cancels the notification but keeps the row', () async {
    final created = await service.create(text: 'uno', dueAt: DateTime(2026, 7, 23, 9));
    expect(scheduler.scheduled, hasLength(1));

    await service.setEnabled(created, false);

    expect(scheduler.cancelled.single.uuid, created.uuid); // alarm cancelled
    final list = await service.list(now: now);
    expect(list, hasLength(1)); // row still visible
    expect(list.single.isDisabled, isTrue);
  });

  test('re-enable reschedules and returns to pending', () async {
    final created = await service.create(text: 'uno', dueAt: DateTime(2026, 7, 23, 9));
    await service.setEnabled(created, false);
    scheduler.scheduled.clear();

    final disabled = (await service.list(now: now)).single;
    await service.setEnabled(disabled, true);

    expect(scheduler.scheduled, hasLength(1)); // re-armed
    expect((await service.list(now: now)).single.status, LocalReminderStatus.pending);
  });

  test('edit changes content and re-arms at the new instant', () async {
    final created = await service.create(text: 'llamar', dueAt: DateTime(2026, 7, 23, 9));
    scheduler.scheduled.clear();

    await service.edit(
      created,
      text: 'llamar al doctor',
      dueAt: DateTime(2026, 7, 24, 18),
      recurrence: ReminderRecurrence.daily,
    );

    expect(scheduler.cancelled.single.uuid, created.uuid); // old alarm cancelled
    final armed = scheduler.scheduled.single; // new alarm
    expect(armed.text, 'llamar al doctor');
    expect(armed.dueAt, DateTime(2026, 7, 24, 18));
    expect(armed.recurrence, ReminderRecurrence.daily);

    final stored = (await service.list(now: now)).single;
    expect(stored.text, 'llamar al doctor');
    expect(stored.dueAt, DateTime(2026, 7, 24, 18));
  });
}
