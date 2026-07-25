import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/notifications/app_notifications.dart';
import 'package:lifeos/core/timezone/effective_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

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

  group('scheduleInstant — the daily wall-clock rule', () {
    setUpAll(EffectiveTimezoneResolver.ensureDatabase);

    test('a daily repeat anchors the PICKED wall time in the effective zone', () {
      // Regression: the recurring anchor used TZDateTime.from (instant
      // conversion), so a 07:00 device-local pick with a Madrid override
      // anchored at 14:00 Madrid — and drifted an hour off the displayed
      // "07:00" after Madrid's DST switch.
      final madrid = tz.getLocation('Europe/Madrid');
      final picked = DateTime(2026, 1, 10, 7, 0); // device-local 07:00

      final when = AppNotifications.scheduleInstant(
        scheduledAt: picked,
        repeatDailyAtTime: true,
        location: madrid,
      );

      expect(when.location, madrid);
      expect(when.hour, 7, reason: 'the anchor agrees with the displayed 07:00');
      expect(when.minute, 0);
    });

    test('a one-shot preserves the absolute INSTANT', () {
      final madrid = tz.getLocation('Europe/Madrid');
      final picked = DateTime(2026, 1, 10, 7, 0);

      final when = AppNotifications.scheduleInstant(
        scheduledAt: picked,
        repeatDailyAtTime: false,
        location: madrid,
      );

      expect(when.millisecondsSinceEpoch, picked.millisecondsSinceEpoch,
          reason: 'zone re-labels the wall clock, the moment does not move');
    });

    test('no location falls back to the previous UTC-instant behavior', () {
      final picked = DateTime(2026, 1, 10, 7, 0);
      final when = AppNotifications.scheduleInstant(
        scheduledAt: picked,
        repeatDailyAtTime: true,
      );
      expect(when.location, tz.UTC);
      expect(when.millisecondsSinceEpoch, picked.millisecondsSinceEpoch);
    });
  });
}
