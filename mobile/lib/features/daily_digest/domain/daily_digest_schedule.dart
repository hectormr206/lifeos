/// The user's daily-digest schedule: whether the on-device daily summary runs
/// automatically and at which local wall-clock time.
///
/// STANDING RULE ("everything ON by default"): unlike the morning briefing's
/// original opt-in schedule, the daily digest is ENABLED BY DEFAULT at a
/// sensible evening hour (21:00) — the user opts OUT. It is a BUILT-IN and can
/// be edited (time) or deactivated, but never deleted.
///
/// Pure value object + pure date math, so the trigger logic is unit-testable
/// with plain [DateTime]s and no platform channels (mirrors BriefingSchedule).
///
/// TIMEZONE: [nextRun]/[shouldRunNow] take an optional [tz.Location] — `null`
/// (AUTOMATIC) interprets the wall-clock in device-local time (unchanged); a
/// manual override interprets it in that zone (DST-aware).
library;

import 'package:timezone/timezone.dart' as tz;

class DailyDigestSchedule {
  const DailyDigestSchedule({
    this.enabled = true,
    this.hour = defaultHour,
    this.minute = defaultMinute,
  });

  /// Default-ON, at 21:00 — end-of-day recap of what was captured today.
  static const int defaultHour = 21;
  static const int defaultMinute = 0;

  /// Whether the automatic daily digest is on.
  final bool enabled;

  /// Local wall-clock hour (0–23) the digest should run at.
  final int hour;

  /// Local wall-clock minute (0–59) the digest should run at.
  final int minute;

  DailyDigestSchedule copyWith({bool? enabled, int? hour, int? minute}) =>
      DailyDigestSchedule(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  /// The next instant (device-local time) the schedule should fire, given
  /// [now]. Skips today's slot when it already passed, and also when a digest
  /// was already generated today ([lastGeneratedAt]).
  DateTime nextRun(DateTime now, {DateTime? lastGeneratedAt, tz.Location? location}) {
    final lastLocal = _inZone(lastGeneratedAt, location);
    var candidate = _slot(now, now.day, location);
    if (!candidate.isAfter(now) ||
        (lastLocal != null && _sameDay(candidate, lastLocal))) {
      candidate = _slot(now, now.day + 1, location);
    }
    return candidate;
  }

  /// Whether an automatic run is due RIGHT NOW: enabled, today's slot passed,
  /// and no digest generated today yet ([lastGeneratedAt] guard).
  bool shouldRunNow(DateTime now, {DateTime? lastGeneratedAt, tz.Location? location}) {
    if (!enabled) return false;
    final todaySlot = _slot(now, now.day, location);
    if (now.isBefore(todaySlot)) return false;
    final lastLocal = _inZone(lastGeneratedAt, location);
    if (lastLocal != null && _sameDay(now, lastLocal)) return false;
    return true;
  }

  /// The `hour:minute` slot on [ref]'s (year, month, [day]) — built in
  /// [location] when given (DST-aware), else device-local.
  DateTime _slot(DateTime ref, int day, tz.Location? location) => location == null
      ? DateTime(ref.year, ref.month, day, hour, minute)
      : tz.TZDateTime(location, ref.year, ref.month, day, hour, minute);

  static DateTime? _inZone(DateTime? t, tz.Location? location) =>
      t == null || location == null ? t : tz.TZDateTime.from(t, location);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  bool operator ==(Object other) =>
      other is DailyDigestSchedule &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);

  @override
  String toString() => 'DailyDigestSchedule(enabled: $enabled, $hour:$minute)';
}
