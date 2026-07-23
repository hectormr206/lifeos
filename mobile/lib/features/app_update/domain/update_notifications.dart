import '../../../core/notifications/app_notifications.dart';

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

/// Production [UpdateNotifications] backed by the shared [AppNotifications].
///
/// A single fixed notification id is reused so re-notifications about a still
/// pending update replace (not stack) the previous one. POST_NOTIFICATIONS is
/// already declared in the manifest and requested for the model download; on
/// Android 13+ a denied permission simply means the notification is suppressed
/// (never a crash) — the in-app banner still surfaces the update.
///
/// Tap handling + plugin initialization are delegated to [AppNotifications] so
/// the update handler and the briefing handler share ONE `initialize()` and
/// coexist in one payload → handler registry (neither clobbers the other).
class FlutterLocalUpdateNotifications implements UpdateNotifications {
  FlutterLocalUpdateNotifications([AppNotifications? notifications])
      : _notifications = notifications ?? AppNotifications.instance;

  final AppNotifications _notifications;

  static const int _notificationId = 4210;
  // Bumped from 'lifeos_app_updates' to '..._v2': on Android 8+ a channel's
  // importance is cached at creation and cannot be raised by code, so the old
  // default-importance channel would keep suppressing the heads-up pop-up on
  // devices that already ran an earlier build. A fresh id lets the new
  // HIGH-importance channel take effect.
  static const String _channelId = 'lifeos_app_updates_v2';
  static const String _channelName = 'Actualizaciones de la app';

  /// Payload attached to the notification so a tap is dispatched to the update
  /// handler (never confused with the briefing tap) and routed to the updates
  /// screen.
  static const String _payload = 'app_update';

  @override
  Future<void> registerTapHandler(void Function() onTapUpdate) =>
      _notifications.registerTapHandler(_payload, onTapUpdate);

  @override
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == _payload;

  @override
  Future<void> showUpdateAvailable(String versionName) => _notifications.show(
        id: _notificationId,
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: 'Avisos cuando hay una nueva versión de LifeOS.',
        title: 'Actualización disponible',
        body: 'Versión $versionName lista — toca para actualizar LifeOS.',
        payload: _payload,
      );
}
