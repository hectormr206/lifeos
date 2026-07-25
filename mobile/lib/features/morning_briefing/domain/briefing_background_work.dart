/// OS background-execution trigger for the "Boletín automático": a WorkManager
/// one-off task that generates the briefing FOR REAL with the app closed.
///
/// PRODUCT DECISION (user opt-in, "Segundo plano"): the briefing must exist by
/// the scheduled hour without opening the app, accepting the battery/RAM cost
/// of fetching + (when the ~2.6GB model is on disk) translating headless. The
/// old design — reminder notification + generate-on-open — remains as the
/// graceful floor when the OS defers or kills the background task.
///
/// Abstract so the notifier depends on the interface and tests inject a fake
/// (no workmanager plugin channel).
abstract class BriefingBackgroundWork {
  /// Schedule (replacing any previous one) the one-off background generation
  /// to run after [initialDelay] — the distance to the next scheduled slot in
  /// the effective zone. Best-effort: failures must not throw.
  Future<void> scheduleOneOff(Duration initialDelay);

  /// Cancel the pending background generation (schedule disabled).
  Future<void> cancel();
}
