import 'package:timezone/timezone.dart' as tz;

/// The user's "Boletín automático" setting: whether the briefing should be
/// triggered daily and at which local wall-clock time (default 8:00, ENABLED —
/// the "everything-on" default; the user opts out).
///
/// Pure value object + pure date math so the trigger logic (when is the next
/// run? should we auto-run right now?) is unit-testable with plain [DateTime]s
/// and no platform channels.
///
/// TIMEZONE: [nextRun]/[shouldRunNow] take an optional [tz.Location]. When it is
/// `null` (AUTOMATIC mode) the wall-clock (`hour:minute`) is interpreted in the
/// device-local zone, exactly as before. When a manual override [tz.Location] is
/// passed, the same wall-clock is interpreted in THAT zone (DST-aware), so an
/// 08:00 briefing fires at 08:00 in the chosen zone.
class BriefingSchedule {
  const BriefingSchedule({
    this.enabled = true,
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
  DateTime nextRun(DateTime now, {DateTime? lastGeneratedAt, tz.Location? location}) {
    final lastLocal = _inZone(lastGeneratedAt, location);
    var candidate = _slot(now, now.day, location);
    if (!candidate.isAfter(now) ||
        (lastLocal != null && _sameDay(candidate, lastLocal))) {
      candidate = _slot(now, now.day + 1, location);
    }
    return candidate;
  }

  /// Whether an automatic run is due RIGHT NOW: the schedule is enabled,
  /// today's scheduled time already arrived, and no briefing was generated
  /// today yet ([lastGeneratedAt] — the already-generated-today guard).
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
      other is BriefingSchedule &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);

  @override
  String toString() => 'BriefingSchedule(enabled: $enabled, $hour:$minute)';
}
