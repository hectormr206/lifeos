import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts the local "update available" notification (self-hosted OTA update).
///
/// The app had no local-notification mechanism before this feature. Abstract
/// so the notifier is unit-testable with a fake — no
/// `flutter_local_notifications` channel in tests.
abstract class UpdateNotifications {
  /// Show "Nueva versión de LifeOS disponible" for [versionName].
  Future<void> showUpdateAvailable(String versionName);

  /// Register the callback fired when the user taps the update notification
  /// while the app is running (foreground or backgrounded). Initializes the
  /// plugin with the tap handler so a tap deep-links to the updates screen
  /// instead of merely opening the app on its last route.
  Future<void> registerTapHandler(void Function() onTapUpdate);

  /// Whether the app was launched from a killed state by tapping the update
  /// notification — so the caller can route to the updates screen on startup.
  Future<bool> launchedByTap();
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
  void Function()? _onTapUpdate;

  static const int _notificationId = 4210;
  // Bumped from 'lifeos_app_updates' to '..._v2': on Android 8+ a channel's
  // importance is cached at creation and cannot be raised by code, so the old
  // default-importance channel would keep suppressing the heads-up pop-up on
  // devices that already ran an earlier build. A fresh id lets the new
  // HIGH-importance channel take effect.
  static const String _channelId = 'lifeos_app_updates_v2';
  static const String _channelName = 'Actualizaciones de la app';

  /// Payload attached to the notification so a tap can be distinguished from
  /// any future notification kind and routed to the updates screen.
  static const String _payload = 'app_update';

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == _payload) _onTapUpdate?.call();
      },
    );
    _initialized = true;
  }

  @override
  Future<void> registerTapHandler(void Function() onTapUpdate) async {
    _onTapUpdate = onTapUpdate;
    try {
      // Initialize eagerly so a tap while the app is alive is handled even
      // before any notification has been shown this session.
      await _ensureInitialized();
    } catch (_) {
      // No channel (test) — the handler is still stored for a later init.
    }
  }

  @override
  Future<bool> launchedByTap() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      return (details?.didNotificationLaunchApp ?? false) &&
          details?.notificationResponse?.payload == _payload;
    } catch (_) {
      return false;
    }
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
          // HIGH importance + priority so Android shows a floating heads-up
          // (slide-down) notification, not just a status-bar icon.
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _plugin.show(
        id: _notificationId,
        title: 'Actualización disponible',
        body: 'Versión $versionName lista — toca para actualizar LifeOS.',
        notificationDetails: details,
        payload: _payload,
      );
    } catch (_) {
      // No channel (test) / denied permission — never let a notification
      // failure break the update flow; the in-app banner still shows.
    }
  }
}
