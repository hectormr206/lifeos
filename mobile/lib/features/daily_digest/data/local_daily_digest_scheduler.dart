import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/notifications/app_notifications.dart';
import '../domain/daily_digest_scheduler.dart';

/// [DailyDigestScheduler] backed by `flutter_local_notifications.zonedSchedule`
/// (an AlarmManager alarm on Android). Mirrors [LocalBriefingScheduler]: a
/// ONE-SHOT alarm, re-armed by the notifier on every app start / resume /
/// successful generation, converted to a UTC [tz.TZDateTime] preserving the
/// instant (no timezone-database lookup needed for a one-shot). Exact alarm
/// first, falling back to inexact when Android 14+ denies SCHEDULE_EXACT_ALARM.
///
/// Tap handling goes through the shared [AppNotifications] payload registry, so
/// it coexists with the app-update / briefing / reminder handlers.
class LocalDailyDigestScheduler implements DailyDigestScheduler {
  LocalDailyDigestScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    AppNotifications? notifications,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _notifications = notifications ?? AppNotifications.instance;

  final FlutterLocalNotificationsPlugin _plugin;
  final AppNotifications _notifications;

  static const int notificationId = 5320;
  static const String payload = 'daily_digest_scheduled';

  static const String _channelId = 'lifeos_daily_digest_schedule';
  static const String _channelName = 'Resumen diario automático';
  static const String _channelDescription =
      'Recordatorio diario para preparar tu resumen del día.';

  @override
  Future<void> registerTapHandler(void Function() onTap) =>
      _notifications.registerTapHandler(payload, onTap);

  @override
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == payload;

  @override
  Future<void> scheduleReminder(DateTime when) async {
    final scheduledDate = tz.TZDateTime.from(when, tz.UTC);
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        id: notificationId,
        title: 'Tu resumen del día está por prepararse',
        body: 'Toca aquí y Axi resumirá lo que registraste hoy.',
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } catch (_) {
      try {
        await _plugin.zonedSchedule(
          id: notificationId,
          title: 'Tu resumen del día está por prepararse',
          body: 'Toca aquí y Axi resumirá lo que registraste hoy.',
          scheduledDate: scheduledDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
      } catch (_) {
        // No platform channel (tests) / notifications disabled — best-effort.
      }
    }
  }

  @override
  Future<void> cancelReminder() async {
    try {
      await _plugin.cancel(id: notificationId);
    } catch (_) {
      // Best-effort (no channel in tests).
    }
  }
}
