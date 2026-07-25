/// OS-level REMINDER trigger for the scheduled ("Boletín automático") morning
/// briefing — since the "Segundo plano" slice, the FALLBACK layer, not the
/// primary one.
///
/// Trigger layers (all armed for the same next-run instant, all guarded by the
/// shared already-generated-today rule so at most ONE generates):
///   1. PRIMARY: a WorkManager one-off task ([BriefingBackgroundWork]) that
///      generates FOR REAL with the app closed (fetch + assemble + on-device
///      translation when the model file is on disk). User opt-in by product
///      decision, accepting the battery/RAM cost.
///   2. While the app process is alive, an in-app timer runs `generate()`
///      directly at the scheduled time (fully autonomous).
///   3. FLOOR: this OS-scheduled notification fires at the hour ("Tu boletín
///      está listo para generarse — toca aquí"); tapping it (re)launches the
///      app, which auto-runs `generate()` on startup. Covers the OS deferring
///      or killing the background task; the background task removes it when it
///      succeeds first.
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
