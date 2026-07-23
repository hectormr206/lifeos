// Proves LOCAL reminder persistence over the REAL graph store SQL (roadmap
// slice C2): create writes a `kind: 'reminder'` node under the
// 'lifeos-events' graph domain (A3 calendar convention) with the
// {text, dueAt, recurrence, status} payload; list orders/filters; status
// transitions round-trip; delete tombstones. Same host-side ffi backend as
// local_graph_store_test.dart — no schema change involved.
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
  late Database db;
  late LocalRemindersRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    repository = LocalRemindersRepository(SqfliteLocalGraphStore(db));
  });

  tearDown(() async => db.close());

  group('LocalRemindersRepository', () {
    test('create persists a reminder node under the A3 calendar domain', () async {
      final due = DateTime(2026, 7, 23, 8);
      final created = await repository.create(text: 'llamar al doctor', dueAt: due);

      expect(created.uuid, isNotEmpty);
      expect(created.text, 'llamar al doctor');
      expect(created.dueAt, due);
      expect(created.status, LocalReminderStatus.pending);

      // The raw node honors the storage contract (kind + graph domain).
      final store = SqfliteLocalGraphStore(db);
      final node = await store.getNodeByUuid(created.uuid);
      expect(node!.kind, LocalRemindersRepository.nodeKind);
      expect(node.domain, LocalRemindersRepository.graphDomain);
      expect(node.data['text'], 'llamar al doctor');
      expect(node.data['status'], 'pending');
    });

    test('list returns live reminders soonest-first and hides done ones', () async {
      final later = await repository.create(
          text: 'later', dueAt: DateTime(2026, 7, 25, 9));
      await repository.create(text: 'sooner', dueAt: DateTime(2026, 7, 23, 9));
      final done = await repository.create(
          text: 'done', dueAt: DateTime(2026, 7, 22, 9));
      await repository.setStatus(done.uuid, LocalReminderStatus.done);

      final listed = await repository.list();
      expect(listed.map((r) => r.text).toList(), ['sooner', 'later']);

      final all = await repository.list(includeDone: true);
      expect(all.length, 3);
      expect(later.uuid, isNotEmpty);
    });

    test('recurrence and status round-trip through the node data', () async {
      final created = await repository.create(
        text: 'medicina',
        dueAt: DateTime(2026, 7, 23, 7),
        recurrence: ReminderRecurrence.daily,
      );
      expect(created.recurrence, ReminderRecurrence.daily);

      final updated =
          await repository.setStatus(created.uuid, LocalReminderStatus.fired);
      expect(updated!.status, LocalReminderStatus.fired);
      expect(updated.recurrence, ReminderRecurrence.daily);
      expect(updated.text, 'medicina');
    });

    test('delete tombstones the node (gone from list)', () async {
      final created =
          await repository.create(text: 'borrar', dueAt: DateTime(2026, 7, 23));
      expect(await repository.delete(created.uuid), isTrue);
      expect(await repository.list(includeDone: true), isEmpty);
    });
  });

  group('LocalRemindersService', () {
    test('create stores AND schedules with the reminder due instant', () async {
      final scheduler = _RecordingScheduler();
      final service = LocalRemindersService(repository, scheduler);
      final due = DateTime(2026, 7, 23, 8);

      final created = await service.create(text: 'pan', dueAt: due);

      expect(scheduler.scheduled, hasLength(1));
      expect(scheduler.scheduled.single.uuid, created.uuid);
      expect(scheduler.scheduled.single.dueAt, due);
    });

    test('list moves overdue one-shots to fired, keeps daily pending', () async {
      final scheduler = _RecordingScheduler();
      final service = LocalRemindersService(repository, scheduler);
      final now = DateTime(2026, 7, 22, 10);
      await service.create(text: 'overdue', dueAt: DateTime(2026, 7, 22, 9));
      await service.create(
        text: 'daily',
        dueAt: DateTime(2026, 7, 22, 7),
        recurrence: ReminderRecurrence.daily,
      );
      await service.create(text: 'upcoming', dueAt: DateTime(2026, 7, 23, 9));

      final listed = await service.list(now: now);

      final byText = {for (final r in listed) r.text: r};
      expect(byText['overdue']!.status, LocalReminderStatus.fired);
      expect(byText['daily']!.status, LocalReminderStatus.pending);
      expect(byText['upcoming']!.status, LocalReminderStatus.pending);
    });

    test('complete cancels the alarm and hides the reminder', () async {
      final scheduler = _RecordingScheduler();
      final service = LocalRemindersService(repository, scheduler);
      final created =
          await service.create(text: 'hecho', dueAt: DateTime(2026, 7, 23, 9));

      await service.complete(created);

      expect(scheduler.cancelled.single.uuid, created.uuid);
      expect(await service.list(now: DateTime(2026, 7, 22)), isEmpty);
    });

    test('reschedulePending re-arms only pending reminders', () async {
      final scheduler = _RecordingScheduler();
      final service = LocalRemindersService(repository, scheduler);
      final now = DateTime(2026, 7, 22, 10);
      await service.create(text: 'upcoming', dueAt: DateTime(2026, 7, 23, 9));
      await service.create(text: 'overdue', dueAt: DateTime(2026, 7, 22, 9));
      scheduler.scheduled.clear();

      await service.reschedulePending(now: now);

      // The overdue one-shot became 'fired' — only the upcoming one re-arms.
      expect(scheduler.scheduled.map((r) => r.text).toList(), ['upcoming']);
    });
  });
}
