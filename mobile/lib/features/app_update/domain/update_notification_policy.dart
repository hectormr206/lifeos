/// Format a [DateTime] as a `yyyy-mm-dd` calendar-day key (local time).
String dayKey(DateTime when) {
  final y = when.year.toString().padLeft(4, '0');
  final m = when.month.toString().padLeft(2, '0');
  final d = when.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Whether to (re-)post the "update available" notification now.
///
/// The rule keeps reminders useful without spamming: notify when this is a
/// *different* update than the one we last notified about (a brand-new build),
/// OR when it's the same build but on a *new calendar day* (a once-a-day
/// reminder while the update stays pending). Repeated checks on the same day
/// for the same build stay silent.
bool shouldNotifyForUpdate({
  required int versionCode,
  required DateTime now,
  required int? lastNotifiedVersionCode,
  required String? lastNotifiedDay,
}) {
  if (lastNotifiedVersionCode != versionCode) return true;
  return lastNotifiedDay != dayKey(now);
}
