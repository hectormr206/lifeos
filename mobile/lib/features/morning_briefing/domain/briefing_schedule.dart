/// The user's "Boletín automático" setting: whether the briefing should be
/// triggered daily and at which local wall-clock time (default 8:00, disabled).
///
/// Pure value object + pure date math so the trigger logic (when is the next
/// run? should we auto-run right now?) is unit-testable with plain [DateTime]s
/// and no platform channels.
class BriefingSchedule {
  const BriefingSchedule({
    this.enabled = false,
    this.hour = defaultHour,
    this.minute = defaultMinute,
  });

  static const int defaultHour = 8;
  static const int defaultMinute = 0;

  /// Whether the daily automatic briefing is on.
  final bool enabled;

  /// Local wall-clock hour (0–23) the briefing should run at.
  final int hour;

  /// Local wall-clock minute (0–59) the briefing should run at.
  final int minute;

  BriefingSchedule copyWith({bool? enabled, int? hour, int? minute}) => BriefingSchedule(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  /// The next instant (device-local time) the schedule should fire, given
  /// [now]. Skips today's slot when it already passed, and also when a
  /// briefing was already generated today ([lastGeneratedAt]) — so generating
  /// manually at 7:50 moves an 8:00 reminder to tomorrow instead of nagging
  /// ten minutes later.
  DateTime nextRun(DateTime now, {DateTime? lastGeneratedAt}) {
    var candidate = DateTime(now.year, now.month, now.day, hour, minute);
    if (!candidate.isAfter(now) ||
        (lastGeneratedAt != null && _sameDay(candidate, lastGeneratedAt))) {
      candidate = DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
    return candidate;
  }

  /// Whether an automatic run is due RIGHT NOW: the schedule is enabled,
  /// today's scheduled time already arrived, and no briefing was generated
  /// today yet ([lastGeneratedAt] — the already-generated-today guard).
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
      other is BriefingSchedule &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);

  @override
  String toString() => 'BriefingSchedule(enabled: $enabled, $hour:$minute)';
}
