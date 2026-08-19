import '../../../core/notifications/app_notifications.dart';

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

/// Production [BriefingNotifications] backed by the shared [AppNotifications].
///
/// Tap handling + plugin initialization are delegated to [AppNotifications] so
/// the briefing handler and the app-update handler share ONE `initialize()`
/// and coexist in one payload → handler registry (neither clobbers the other).
class FlutterLocalBriefingNotifications implements BriefingNotifications {
  FlutterLocalBriefingNotifications([AppNotifications? notifications])
    : _notifications = notifications ?? AppNotifications.instance;

  final AppNotifications _notifications;

  static const int _notificationId = 5310;

  /// SEPARATE channel from the app-update one (`lifeos_app_updates_v2`) so the
  /// briefing gets its own HIGH-importance heads-up notification with its own
  /// name/description in the system settings.
  static const String _channelId = 'lifeos_briefing';
  static const String _channelName = 'Boletín matutino';
  static const String _payload = 'morning_briefing';

  @override
  Future<void> registerTapHandler(void Function() onTapBriefing) =>
      _notifications.registerTapHandler(_payload, onTapBriefing);

  @override
  Future<bool> launchedByTap() async =>
      await _notifications.launchedByTap() == _payload;

  @override
  Future<void> showBriefingReady() => _notifications.show(
    id: _notificationId,
    channelId: _channelId,
    channelName: _channelName,
    channelDescription: 'Avisos cuando tu boletín matutino está listo.',
    title: 'Tu boletín está listo',
    body: 'Toca para leer el boletín matutino que Axi preparó para ti.',
    payload: _payload,
  );
}
