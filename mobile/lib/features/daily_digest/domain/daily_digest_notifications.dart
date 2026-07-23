import '../../../core/notifications/app_notifications.dart';

/// Posts the "tu resumen de hoy está listo" heads-up notification once a daily
/// digest has been generated. Tapping it opens the digest (payload
/// [payload] → routed in app.dart). Separate channel from the schedule reminder
/// so the user can tune them independently in system settings.
///
/// Abstract so the notifier depends on the interface and tests inject a fake
/// (no `flutter_local_notifications` channel in the suite).
abstract class DailyDigestNotifications {
  Future<void> showDigestReady();

  /// Register the tap handler for the "ready" notification.
  Future<void> registerTapHandler(void Function() onTap);

  /// Whether the app was cold-started by tapping the "ready" notification.
  Future<bool> launchedByTap();
}

/// [DailyDigestNotifications] backed by the shared [AppNotifications] registry.
class FlutterLocalDailyDigestNotifications implements DailyDigestNotifications {
  FlutterLocalDailyDigestNotifications([AppNotifications? notifications])
      : _notifications = notifications ?? AppNotifications.instance;

  final AppNotifications _notifications;

  static const int notificationId = 5321;

  /// New payload ('daily_digest' → opens the digest), per the slice spec.
  static const String payload = 'daily_digest';

  static const String channelId = 'lifeos_daily_digest';
  static const String channelName = 'Resumen diario';
  static const String channelDescription =
      'Tu resumen de lo que registraste hoy en el dispositivo.';

  @override
  Future<void> showDigestReady() => _notifications.show(
        id: notificationId,
        channelId: channelId,
        channelName: channelName,
        channelDescription: channelDescription,
        title: 'Tu resumen de hoy está listo',
        body: 'Toca para ver lo que registraste hoy.',
        payload: payload,
      );

  @override
  Future<void> registerTapHandler(void Function() onTap) =>
      _notifications.registerTapHandler(payload, onTap);

  @override
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == payload;
}
