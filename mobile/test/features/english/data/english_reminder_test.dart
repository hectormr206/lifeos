// The daily English reminder, through the REAL reminders service and graph.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/english_reminder.dart';
import 'package:lifeos/features/reminders/data/local_reminders_repository.dart';
import 'package:lifeos/features/reminders/data/local_reminders_service.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Scheduler implements ReminderScheduler {
  final List<LocalReminder> scheduled = [];
  @override
  Future<void> schedule(LocalReminder reminder) async => scheduled.add(reminder);
  @override
  Future<void> cancel(LocalReminder reminder) async {}
}

void main() {
  late Database db;
  late LocalRemindersService service;
  late _Scheduler scheduler;
  final now = DateTime(2026, 9, 25, 21, 0);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    scheduler = _Scheduler();
    service = LocalRemindersService(
        LocalRemindersRepository(SqfliteLocalGraphStore(db)), scheduler);
  });

  tearDown(() async => db.close());

  EnglishReminder reminder(String text) => LocalEnglishReminder(
        service,
        text: text,
        knownTexts: const {'Inglés: tu práctica de hoy', "English: today's practice"},
        clock: () => now,
      );

  test('it is an ordinary daily reminder, scheduled like any other', () async {
    await reminder('Inglés: tu práctica de hoy')
        .create(const TimeOfDay(hour: 22, minute: 0));

    final created = scheduler.scheduled.single;
    expect(created.recurrence, ReminderRecurrence.daily);
    expect(created.text, 'Inglés: tu práctica de hoy');
    expect(created.dueAt, DateTime(2026, 9, 25, 22, 0), reason: 'later today');
  });

  test('a time already gone today starts tomorrow', () async {
    await reminder('Inglés: tu práctica de hoy')
        .create(const TimeOfDay(hour: 7, minute: 30));

    expect(scheduler.scheduled.single.dueAt, DateTime(2026, 9, 26, 7, 30));
  });

  test('an existing one is found, even if made in the other language',
      () async {
    await reminder("English: today's practice")
        .create(const TimeOfDay(hour: 7, minute: 30));

    expect(await reminder('Inglés: tu práctica de hoy').existingTime(),
        const TimeOfDay(hour: 7, minute: 30));
  });

  test('other reminders are not mistaken for it', () async {
    await service.create(
      text: 'Llamar al doctor',
      dueAt: DateTime(2026, 9, 26, 9),
      recurrence: ReminderRecurrence.daily,
    );

    expect(await reminder('Inglés: tu práctica de hoy').existingTime(), isNull);
  });
}
