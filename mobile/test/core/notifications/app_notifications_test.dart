import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/notifications/app_notifications.dart';

void main() {
  // The plugin's platform channel is unavailable in unit tests;
  // registerTapHandler swallows the init failure and still stores the handler.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppNotifications payload dispatch', () {
    test('routes each payload to its OWN registered handler', () async {
      final notifications = AppNotifications();
      var updateTaps = 0;
      var briefingTaps = 0;

      await notifications.registerTapHandler('app_update', () => updateTaps++);
      await notifications.registerTapHandler('morning_briefing', () => briefingTaps++);

      notifications.dispatch('app_update');
      expect(updateTaps, 1, reason: 'update payload fires only the update handler');
      expect(briefingTaps, 0);

      notifications.dispatch('morning_briefing');
      expect(briefingTaps, 1, reason: 'briefing payload fires only the briefing handler');
      expect(updateTaps, 1);
    });

    test('registering the second handler does NOT clobber the first', () async {
      final notifications = AppNotifications();
      var firstFired = false;
      var secondFired = false;

      // First feature wires its handler...
      await notifications.registerTapHandler('app_update', () => firstFired = true);
      // ...then the second feature wires its own (the regression: this used to
      // overwrite the shared onDidReceiveNotificationResponse callback).
      await notifications.registerTapHandler('morning_briefing', () => secondFired = true);

      // The FIRST handler still routes correctly after the second registered.
      notifications.dispatch('app_update');
      expect(firstFired, isTrue, reason: 'first handler survived the second registration');
      expect(secondFired, isFalse);
    });

    test('unknown or null payloads are ignored (no throw, no handler fired)', () async {
      final notifications = AppNotifications();
      var fired = 0;
      await notifications.registerTapHandler('app_update', () => fired++);

      notifications.dispatch(null);
      notifications.dispatch('something_else');

      expect(fired, 0);
    });
  });
}
