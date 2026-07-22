import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts the local "update available" notification (self-hosted OTA update).
///
/// The app had no local-notification mechanism before this feature. Abstract
/// so the notifier is unit-testable with a fake — no
/// `flutter_local_notifications` channel in tests.
abstract class UpdateNotifications {
  /// Show "Nueva versión de LifeOS disponible" for [versionName].
  Future<void> showUpdateAvailable(String versionName);
}

/// Production [UpdateNotifications] backed by `flutter_local_notifications`.
///
/// A single fixed notification id is reused so re-notifications about a still
/// pending update replace (not stack) the previous one. POST_NOTIFICATIONS is
/// already declared in the manifest and requested for the model download; on
/// Android 13+ a denied permission simply means the notification is suppressed
/// (never a crash) — the in-app banner still surfaces the update.
class FlutterLocalUpdateNotifications implements UpdateNotifications {
  FlutterLocalUpdateNotifications([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  static const int _notificationId = 4210;
  static const String _channelId = 'lifeos_app_updates';
  static const String _channelName = 'Actualizaciones de la app';

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  @override
  Future<void> showUpdateAvailable(String versionName) async {
    try {
      await _ensureInitialized();
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Avisos cuando hay una nueva versión de LifeOS.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      );
      await _plugin.show(
        id: _notificationId,
        title: 'Nueva versión de LifeOS disponible',
        body: 'Versión $versionName lista para instalar. Toca para actualizar.',
        notificationDetails: details,
      );
    } catch (_) {
      // No channel (test) / denied permission — never let a notification
      // failure break the update flow; the in-app banner still shows.
    }
  }
}
