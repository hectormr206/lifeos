import 'local_reminder.dart';

/// Schedules/cancels the LOCAL notification for a [LocalReminder] (roadmap
/// slice C2). Abstract so the service/notifier/chat tests can assert
/// "schedule was called with the right instant" with a fake — no
/// `flutter_local_notifications` platform channel in the suite.
abstract class ReminderScheduler {
  /// (Re)schedule [reminder]'s notification at `reminder.dueAt`; a daily
  /// reminder repeats at the same time every day. Idempotent per reminder:
  /// re-scheduling replaces the previous alarm.
  Future<void> schedule(LocalReminder reminder);

  /// Cancel the pending notification for [reminder], if any.
  Future<void> cancel(LocalReminder reminder);
}
