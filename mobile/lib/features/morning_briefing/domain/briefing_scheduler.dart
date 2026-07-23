/// OS-level trigger for the scheduled ("Boletín automático") morning briefing.
///
/// WHY a scheduled NOTIFICATION and not a background isolate: flutter_gemma
/// inference is a synchronous, main-isolate-blocking FFI call, so a
/// WorkManager/alarm background isolate CANNOT load + run the model. The
/// robust path available without new heavy dependencies is:
///   - while the app process is alive, an in-app timer runs `generate()`
///     directly at the scheduled time (fully autonomous), and
///   - when the process is dead, an OS-scheduled notification fires at the
///     hour ("Tu boletín está listo para generarse — toca aquí"); tapping it
///     (re)launches the app, which auto-runs `generate()` on startup.
///
/// Abstract so the notifier depends on the interface and tests inject a fake
/// (no flutter_local_notifications channel, no timezone plumbing).
abstract class BriefingScheduler {
  /// Schedule (replacing any previous one) the OS reminder notification for
  /// [when] (device-local time). Best-effort: failures must not throw.
  Future<void> scheduleReminder(DateTime when);

  /// Cancel the pending OS reminder (schedule disabled, or the briefing was
  /// already generated before the reminder fired).
  Future<void> cancelReminder();

  /// Register the callback fired when the user taps the scheduled reminder
  /// while the app process is alive (foreground or backgrounded).
  Future<void> registerTapHandler(void Function() onTap);

  /// Whether the app was cold-started by tapping the scheduled reminder — so
  /// startup can route to the Boletín screen and auto-run the generation.
  Future<bool> launchedByTap();
}
