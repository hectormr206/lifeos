import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts the local "tu boletín está listo" notification for the ON-DEVICE
/// morning briefing.
///
/// Mirrors the app-update notification pattern ([UpdateNotifications]) — same
/// abstraction so the notifier is unit-testable with a fake (no
/// `flutter_local_notifications` channel in tests) — but uses a SEPARATE HIGH
/// importance channel (`lifeos_briefing`) and its own payload so a briefing tap
/// is never confused with an update tap.
abstract class BriefingNotifications {
  /// Show "Tu boletín está listo" once a briefing has been generated.
  Future<void> showBriefingReady();

  /// Register the callback fired when the user taps the briefing notification
  /// while the app is running. Initializes the plugin with the tap handler so a
  /// tap deep-links to the Boletín screen.
  Future<void> registerTapHandler(void Function() onTapBriefing);

  /// Whether the app was launched from a killed state by tapping the briefing
  /// notification — so the caller can route to the Boletín screen on startup.
  Future<bool> launchedByTap();
}

/// Production [BriefingNotifications] backed by `flutter_local_notifications`.
class FlutterLocalBriefingNotifications implements BriefingNotifications {
  FlutterLocalBriefingNotifications([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  void Function()? _onTapBriefing;

  static const int _notificationId = 5310;

  /// SEPARATE channel from the app-update one (`lifeos_app_updates_v2`) so the
  /// briefing gets its own HIGH-importance heads-up notification with its own
  /// name/description in the system settings.
  static const String _channelId = 'lifeos_briefing';
  static const String _channelName = 'Boletín matutino';
  static const String _payload = 'morning_briefing';

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == _payload) _onTapBriefing?.call();
      },
    );
    _initialized = true;
  }

  @override
  Future<void> registerTapHandler(void Function() onTapBriefing) async {
    _onTapBriefing = onTapBriefing;
    try {
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
  Future<void> showBriefingReady() async {
    try {
      await _ensureInitialized();
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Avisos cuando tu boletín matutino está listo.',
          // HIGH importance + priority so Android shows a floating heads-up
          // notification, matching the app-update channel behavior.
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _plugin.show(
        id: _notificationId,
        title: 'Tu boletín está listo',
        body: 'Toca para leer el boletín matutino que Axi preparó para ti.',
        notificationDetails: details,
        payload: _payload,
      );
    } catch (_) {
      // No channel (test) / denied permission — never let a notification
      // failure break the pipeline; the briefing still shows in-app.
    }
  }
}
