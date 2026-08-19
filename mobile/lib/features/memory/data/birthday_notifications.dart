// Scheduling the birthday nudges.
//
// Thin on purpose: `birthdayNudges` decides WHAT and WHEN (and is fully
// tested), this only hands the result to the platform. Its own channel, so
// someone who mutes birthdays keeps their reminders — muting the only channel
// they had would be the difference between "too noisy" and "uninstalled".
library;

import 'package:timezone/timezone.dart' as tz;

import '../../../core/notifications/app_notifications.dart';
import '../domain/birthday_nudges.dart';

class BirthdayNotifications {
  BirthdayNotifications({
    AppNotifications? notifications,
    this._locationResolver,
  }) : _notifications = notifications ?? AppNotifications.instance;

  final AppNotifications _notifications;
  final Future<tz.Location?> Function()? _locationResolver;

  static const String channelId = 'lifeos_birthdays';
  static const String channelName = 'Cumpleaños';
  static const String channelDescription =
      'Avisos de los cumpleaños de tus personas.';

  /// The payload a tap carries, so it can open the people screen.
  static const String payload = 'birthday';

  /// Schedule every nudge. Ids are stable, so this REPLACES rather than
  /// stacking: safe to call on every launch and after every sync.
  Future<void> scheduleAll(List<BirthdayNudge> nudges) async {
    tz.Location? location;
    if (_locationResolver != null) {
      try {
        location = await _locationResolver();
      } catch (_) {
        location = null;
      }
    }
    for (final nudge in nudges) {
      try {
        await _notifications.zonedSchedule(
          id: nudge.id,
          channelId: channelId,
          channelName: channelName,
          channelDescription: channelDescription,
          title: 'Cumpleaños',
          body: nudge.message,
          payload: payload,
          scheduledAt: nudge.at,
          location: location,
        );
      } catch (_) {
        // One nudge failing must not take the rest with it: a denied
        // permission or a full alarm slot is per-notification on Android.
      }
    }
  }
}
