import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/notifications/app_notifications.dart';
import '../domain/briefing_scheduler.dart';

/// [BriefingScheduler] backed by `flutter_local_notifications.zonedSchedule`
/// (an AlarmManager alarm on Android). Since the "Segundo plano" slice this is
/// the FALLBACK reminder layer; the primary trigger is the WorkManager one-off
/// ([WorkmanagerBriefingBackgroundWork]) that generates headless and removes
/// this reminder when it succeeds first.
///
/// Design notes:
///   - ONE-SHOT alarm, re-armed by the notifier on every app start / resume /
///     successful generation, instead of `matchDateTimeComponents` daily
///     repetition. Rearming keeps the "skip if already generated today" and
///     "user changed the hour" logic in ONE place (the Dart side) and avoids
///     the repeat-in-UTC-wall-clock pitfall below.
///   - The scheduled instant is computed in device-local time as a plain
///     [DateTime] and converted to a UTC [tz.TZDateTime] preserving the
///     INSTANT. `tz.UTC` needs no timezone-database initialization, and
///     AlarmManager fires on the instant, so a one-shot alarm lands at the
///     right local time without initializing/detecting the device zone. (A
///     REPEATING schedule could drift across a DST change — another reason
///     for the one-shot + rearm design.)
///   - Exact alarm first (`exactAllowWhileIdle`), falling back to inexact
///     (`inexactAllowWhileIdle`, up to ~15 min late) when Android 14+ denies
///     the SCHEDULE_EXACT_ALARM special access.
///   - Tap handling goes through the shared [AppNotifications] payload
///     registry (its public API), so this handler coexists with the
///     app-update and briefing-ready handlers without clobbering them. The
///     plugin instance here only schedules/cancels; all instances share the
///     same platform implementation underneath.
class LocalBriefingScheduler implements BriefingScheduler {
  LocalBriefingScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    AppNotifications? notifications,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _notifications = notifications ?? AppNotifications.instance;

  final FlutterLocalNotificationsPlugin _plugin;
  final AppNotifications _notifications;

  static const int notificationId = 5311;
  static const String payload = 'morning_briefing_scheduled';

  /// Separate channel from `lifeos_briefing` ("listo") so the user can tune
  /// the daily reminder independently in system settings.
  static const String _channelId = 'lifeos_briefing_schedule';
  static const String _channelName = 'Boletín automático';
  static const String _channelDescription =
      'Recordatorio diario para generar tu boletín matutino.';

  @override
  Future<void> registerTapHandler(void Function() onTap) =>
      _notifications.registerTapHandler(payload, onTap);

  @override
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == payload;

  @override
  Future<void> scheduleReminder(DateTime when) async {
    // Instant-preserving conversion; see the class doc for why UTC is safe
    // (and database-free) for a one-shot alarm.
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
        title: 'Tu boletín no se generó solo',
        body: 'El sistema pospuso la tarea. Toca aquí para prepararlo ahora.',
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } catch (_) {
      // Exact alarms denied (Android 14+ default) — an inexact alarm still
      // fires within ~15 minutes, plenty for a morning briefing.
      try {
        await _plugin.zonedSchedule(
          id: notificationId,
          title: 'Tu boletín no se generó solo',
          body: 'El sistema pospuso la tarea. Toca aquí para prepararlo ahora.',
          scheduledDate: scheduledDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
        );
      } catch (_) {
        // No platform channel (tests) / notifications disabled — scheduling is
        // best-effort and must never break its caller.
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
