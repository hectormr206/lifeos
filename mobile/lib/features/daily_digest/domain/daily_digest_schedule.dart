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
  DateTime nextRun(DateTime now, {DateTime? lastGeneratedAt}) {
    var candidate = DateTime(now.year, now.month, now.day, hour, minute);
    if (!candidate.isAfter(now) ||
        (lastGeneratedAt != null && _sameDay(candidate, lastGeneratedAt))) {
      candidate = DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
    return candidate;
  }

  /// Whether an automatic run is due RIGHT NOW: enabled, today's slot passed,
  /// and no digest generated today yet ([lastGeneratedAt] guard).
  bool shouldRunNow(DateTime now, {DateTime? lastGeneratedAt}) {
    if (!enabled) return false;
    final todaySlot = DateTime(now.year, now.month, now.day, hour, minute);
    if (now.isBefore(todaySlot)) return false;
    if (lastGeneratedAt != null && _sameDay(now, lastGeneratedAt)) return false;
    return true;
  }

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
