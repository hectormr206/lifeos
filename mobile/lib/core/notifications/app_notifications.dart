import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Single owner of the app's [FlutterLocalNotificationsPlugin].
///
/// `FlutterLocalNotificationsPlugin` is a process-wide singleton and its
/// `initialize(onDidReceiveNotificationResponse: …)` keeps only the LAST
/// callback it was given. When two features (app-update and morning-briefing)
/// each called `initialize()` with their own tap handler, the second wired one
/// SILENTLY OVERWROTE the first — so tapping the update notification fired the
/// briefing handler (whose payload check didn't match) and nothing happened.
///
/// This component fixes that by initializing the plugin EXACTLY ONCE with a
/// SINGLE `onDidReceiveNotificationResponse` that DISPATCHES by payload to a
/// registry of per-payload handlers. Every feature registers its handler +
/// shows its notifications through here, so the handlers coexist and neither
/// clobbers the other.
class AppNotifications {
  AppNotifications([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Process-wide default used by the production feature notifiers so they all
  /// share ONE plugin, ONE `initialize`, and ONE tap-handler registry.
  static final AppNotifications instance = AppNotifications();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  /// payload → tap handler. One entry per notification kind
  /// (`'app_update'`, `'morning_briefing'`, …).
  final Map<String, void Function()> _handlers = {};

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => dispatch(response.payload),
    );
    _initialized = true;
  }

  /// Routes a tapped notification's [payload] to the handler that registered
  /// for it. Unknown/absent payloads are ignored. Exposed for unit tests so
  /// payload dispatch is verifiable without a platform channel.
  @visibleForTesting
  void dispatch(String? payload) {
    if (payload == null) return;
    _handlers[payload]?.call();
  }

  /// Register the tap handler for [payload] (foreground/background taps). Does
  /// NOT replace handlers registered for OTHER payloads. Initializes the plugin
  /// eagerly so a tap while the app is alive is handled even before any
  /// notification has been shown this session; a missing channel (tests) is
  /// swallowed and the handler is still stored for a later init.
  Future<void> registerTapHandler(String payload, void Function() onTap) async {
    _handlers[payload] = onTap;
    try {
      await _ensureInitialized();
    } catch (_) {
      // No channel (test) — the handler is kept for a later init/dispatch.
    }
  }

  /// The payload of the notification that cold-started the app from a killed
  /// state, or `null` if the app was not launched by a notification tap. The
  /// caller matches it against its own payload to route on startup.
  Future<String?> launchedByTap() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (!(details?.didNotificationLaunchApp ?? false)) return null;
      return details?.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }

  /// Show a heads-up notification on the given channel, tagged with [payload]
  /// so a tap routes back to the right handler via [dispatch]. Ensures the
  /// plugin is initialized first; any failure (no channel in tests / denied
  /// permission) is swallowed so a notification never breaks its caller's flow.
  Future<void> show({
    required int id,
    required String channelId,
    required String channelName,
    required String channelDescription,
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      await _ensureInitialized();
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          // HIGH importance + priority so Android shows a floating heads-up
          // (slide-down) notification, not just a status-bar icon.
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } catch (_) {
      // No channel (test) / denied permission — never let a notification
      // failure break the caller's flow.
    }
  }
}
