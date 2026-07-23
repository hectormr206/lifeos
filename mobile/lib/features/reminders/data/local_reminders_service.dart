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

  /// Edit a reminder's content (text/time/recurrence) and re-arm its alarm.
  /// Cancels the old alarm first so a changed time never leaves a stale one.
  /// Editing re-activates the reminder (a previously disabled one turns back on).
  Future<void> edit(
    LocalReminder reminder, {
    required String text,
    required DateTime dueAt,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
  }) async {
    await _scheduler.cancel(reminder);
    final updated = await _repository.update(
      reminder.uuid,
      text: text,
      dueAt: dueAt,
      recurrence: recurrence,
    );
    if (updated != null) await _scheduler.schedule(updated);
  }

  /// Enable/disable a reminder WITHOUT deleting it. Disabling cancels the
  /// scheduled notification and keeps the row (status → disabled); enabling
  /// returns it to pending and reschedules its alarm.
  Future<void> setEnabled(LocalReminder reminder, bool enabled) async {
    if (enabled) {
      final updated =
          await _repository.setStatus(reminder.uuid, LocalReminderStatus.pending);
      if (updated != null) await _scheduler.schedule(updated);
    } else {
      await _scheduler.cancel(reminder);
      await _repository.setStatus(reminder.uuid, LocalReminderStatus.disabled);
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
