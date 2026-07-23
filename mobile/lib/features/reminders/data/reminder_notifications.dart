import '../../../core/notifications/app_notifications.dart';
import '../domain/local_reminder.dart';
import '../domain/reminder_scheduler.dart';

/// Production [ReminderScheduler] backed by the shared [AppNotifications]
/// registry (roadmap slice C2).
///
/// Mirrors the briefing/app-update pattern: its OWN high-importance channel
/// (`lifeos_reminders`) and its OWN payload (`'reminder'`) registered through
/// the single payload-dispatch registry, so a reminder tap never collides
/// with the update/briefing handlers.
class NotificationReminderScheduler implements ReminderScheduler {
  NotificationReminderScheduler([AppNotifications? notifications])
      : _notifications = notifications ?? AppNotifications.instance;

  final AppNotifications _notifications;

  static const String channelId = 'lifeos_reminders';
  static const String channelName = 'Recordatorios';
  static const String channelDescription =
      'Recordatorios que creaste con Axi en este dispositivo.';

  /// The payload every scheduled reminder notification carries — the
  /// dispatch key in [AppNotifications]. A tap routes to the reminders
  /// screen via [registerTapHandler].
  static const String payload = 'reminder';

  @override
  Future<void> schedule(LocalReminder reminder) => _notifications.zonedSchedule(
        id: reminder.notificationId,
        channelId: channelId,
        channelName: channelName,
        channelDescription: channelDescription,
        title: 'Recordatorio',
        body: reminder.text,
        payload: payload,
        scheduledAt: reminder.dueAt,
        repeatDailyAtTime: reminder.recurrence == ReminderRecurrence.daily,
      );

  @override
  Future<void> cancel(LocalReminder reminder) =>
      _notifications.cancelScheduled(reminder.notificationId);

  /// Register the tap handler for the `'reminder'` payload (open the
  /// reminders screen). Registered by the reminders UI/service when it comes
  /// alive; see the TODO in `local_reminders_providers.dart` about cold-start
  /// routing (app.dart wiring is deferred — that file is being reworked by
  /// the morning-briefing scheduling slice in parallel).
  Future<void> registerTapHandler(void Function() onTap) =>
      _notifications.registerTapHandler(payload, onTap);

  /// Whether the app was cold-started by tapping a reminder notification.
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == payload;
}
