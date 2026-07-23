/// OS-level trigger for the automatic on-device daily digest.
///
/// Same design as [BriefingScheduler]: on-device model inference is a
/// main-isolate-blocking FFI call, so a background isolate cannot run it. While
/// the app is alive an in-app timer runs `generate()` at the scheduled time;
/// when the process is dead an OS-scheduled notification fires at the hour and
/// tapping it (re)launches the app, which auto-runs `generate()` on startup.
///
/// Abstract so the notifier depends on the interface and tests inject a fake.
abstract class DailyDigestScheduler {
  /// Schedule (replacing any previous one) the OS reminder for [when]
  /// (device-local time). Best-effort: failures must not throw.
  Future<void> scheduleReminder(DateTime when);

  /// Cancel the pending OS reminder.
  Future<void> cancelReminder();

  /// Register the callback fired when the user taps the scheduled reminder
  /// while the app process is alive.
  Future<void> registerTapHandler(void Function() onTap);

  /// Whether the app was cold-started by tapping the scheduled reminder.
  Future<bool> launchedByTap();
}
