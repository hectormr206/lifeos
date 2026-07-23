import '../domain/local_reminder.dart';
import '../domain/reminder_scheduler.dart';
import 'local_reminders_repository.dart';

/// The one write-path for LOCAL reminders (roadmap slice C2): every create/
/// complete/delete goes through here so the graph row and the scheduled
/// notification NEVER drift apart. Used by both the reminders screen and the
/// chat's deterministic "recuérdame…" intent.
class LocalRemindersService {
  LocalRemindersService(this._repository, this._scheduler);

  final LocalRemindersRepository _repository;
  final ReminderScheduler _scheduler;

  /// Persist + schedule. The notification failing to schedule (denied
  /// permission, test host) never loses the stored reminder — the store is
  /// the source of truth, the alarm is best-effort (AppNotifications'
  /// swallow-errors contract).
  Future<LocalReminder> create({
    required String text,
    required DateTime dueAt,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
  }) async {
    final reminder = await _repository.create(
      text: text,
      dueAt: dueAt,
      recurrence: recurrence,
    );
    await _scheduler.schedule(reminder);
    return reminder;
  }

  /// Live reminders, soonest first. Before listing, one-shot reminders whose
  /// due instant already passed are moved `pending → fired` so the UI shows
  /// them under their real state (the notification fired — or its moment
  /// went by while the device was off). Daily reminders stay pending: their
  /// schedule keeps repeating natively.
  Future<List<LocalReminder>> list({required DateTime now}) async {
    final reminders = await _repository.list();
    var changed = false;
    for (final reminder in reminders) {
      if (reminder.status == LocalReminderStatus.pending &&
          reminder.recurrence == ReminderRecurrence.none &&
          !reminder.dueAt.isAfter(now)) {
        await _repository.setStatus(reminder.uuid, LocalReminderStatus.fired);
        changed = true;
      }
    }
    return changed ? _repository.list() : reminders;
  }

  /// Re-arm the alarms for everything still pending — alarms do not survive
  /// a reboot, so this runs when the reminders surface loads. Idempotent:
  /// scheduling by the same notification id replaces, never duplicates.
  Future<void> reschedulePending({required DateTime now}) async {
    for (final reminder in await list(now: now)) {
      if (reminder.status == LocalReminderStatus.pending) {
        await _scheduler.schedule(reminder);
      }
    }
  }

  Future<void> complete(LocalReminder reminder) async {
    await _scheduler.cancel(reminder);
    await _repository.setStatus(reminder.uuid, LocalReminderStatus.done);
  }

  Future<void> delete(LocalReminder reminder) async {
    await _scheduler.cancel(reminder);
    await _repository.delete(reminder.uuid);
  }
}
