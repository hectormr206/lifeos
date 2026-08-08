// The Pixel notified. The laptop stayed silent. Same app, same code path.
//
// WHY. `AppNotifications` initialized the plugin with ANDROID settings only:
//
//     InitializationSettings(android: AndroidInitializationSettings(...))
//
// `flutter_local_notifications` initializes exactly the platforms it is given.
// On Linux nothing was configured, so `show()` posted nothing and swallowed the
// result — the app was silently notification-less on the desktop while
// reporting no problem at all. The user's requirement is the opposite: the same
// behaviour on the Pixel, on Linux, and on whatever we ship next.
//
// These tests are on the PURE builders rather than the plugin, because there is
// no D-Bus notification daemon in CI and there is no need for one to prove the
// settings are built for the platform the app is running on.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/notifications/app_notifications.dart';

void main() {
  group('initialization settings per platform', () {
    test('Linux is initialized — this is the defect', () {
      final settings = AppNotifications.initializationSettingsFor('linux');

      expect(settings.linux, isNotNull,
          reason: 'no linux settings means show() posts nothing, silently');
      // The default action is what makes a click on the bubble reach
      // onDidReceiveNotificationResponse with our payload.
      expect(settings.linux!.defaultActionName, isNotEmpty);
    });

    test('Android still gets its settings — the Pixel holds the real data', () {
      final settings = AppNotifications.initializationSettingsFor('android');

      expect(settings.android, isNotNull);
    });
  });

  group('notification details per platform', () {
    test('Linux details are built (channels are an Android concept)', () {
      final details = AppNotifications.detailsFor(
        operatingSystem: 'linux',
        channelId: 'lifeos_app_updates_v2',
        channelName: 'Actualizaciones de la app',
        channelDescription: 'Avisos cuando hay una nueva versión de LifeOS.',
      );

      expect(details.linux, isNotNull);
      // Same intent as Android's Importance.high: the desktop bubble should be
      // noticed, not filed away.
      expect(details.linux!.urgency, isNotNull);
    });

    test('Android keeps its HIGH-importance channel', () {
      final details = AppNotifications.detailsFor(
        operatingSystem: 'android',
        channelId: 'lifeos_app_updates_v2',
        channelName: 'Actualizaciones de la app',
        channelDescription: 'Avisos cuando hay una nueva versión de LifeOS.',
      );

      expect(details.android, isNotNull);
      expect(details.android!.channelId, 'lifeos_app_updates_v2');
    });
  });
}
