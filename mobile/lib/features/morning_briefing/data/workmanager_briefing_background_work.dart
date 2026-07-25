import 'package:workmanager/workmanager.dart';

import '../domain/briefing_background_work.dart';

/// The `taskName` WorkManager hands back to the callback dispatcher — the
/// switch key in `core/background/background_tasks.dart`.
const String morningBriefingTaskName = 'morning_briefing_generate';

/// The unique WorkManager work name: re-registering under the same name with
/// [ExistingWorkPolicy.replace] keeps AT MOST ONE pending generation, so a
/// schedule/timezone change (or the post-run re-arm) never stacks tasks.
const String morningBriefingUniqueWorkName = 'lifeos_morning_briefing_oneoff';

/// [BriefingBackgroundWork] backed by the `workmanager` plugin (Android
/// WorkManager).
///
/// Design notes:
///   - ONE-OFF task re-armed after every run (by the notifier when the app is
///     open, by the background task itself when it isn't), mirroring the
///     one-shot + rearm design of [LocalBriefingScheduler] — same reasons: the
///     next-run math (skip-if-generated-today, user-changed-hour, timezone
///     override) lives in ONE place, `BriefingSchedule.nextRun`.
///   - `NetworkType.connected` constraint: a briefing without network fetches
///     nothing, so let WorkManager hold the task until connectivity exists.
///   - BATTERY HONESTY: when the on-device model file is present the task
///     loads a ~2.6GB LLM headless to translate. That is heavy and
///     INTENTIONAL — the user explicitly chose background generation over the
///     tap-to-generate flow. If the OS defers/kills the task, the scheduled
///     reminder notification + generate-on-open path still works.
///   - Best-effort like every scheduler in this app: no platform channel
///     (tests) / WorkManager unavailable must never break the caller.
class WorkmanagerBriefingBackgroundWork implements BriefingBackgroundWork {
  WorkmanagerBriefingBackgroundWork({Workmanager? workmanager})
      : _workmanager = workmanager ?? Workmanager();

  final Workmanager _workmanager;

  @override
  Future<void> scheduleOneOff(Duration initialDelay) async {
    try {
      await _workmanager.registerOneOffTask(
        morningBriefingUniqueWorkName,
        morningBriefingTaskName,
        // Never negative: an overdue instant runs as soon as constraints allow.
        initialDelay: initialDelay.isNegative ? Duration.zero : initialDelay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {
      // No plugin channel (tests) / OS refusal — scheduling is best-effort;
      // the reminder-notification fallback still covers the hour.
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _workmanager.cancelByUniqueName(morningBriefingUniqueWorkName);
    } catch (_) {
      // Best-effort (no channel in tests).
    }
  }
}
