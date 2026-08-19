// What has to happen on THIS device once a sync pass brings rows in.
//
// Reminders live in the synced graph, so the row arrives on every device by
// itself. The alarm does not: rescheduling only ever ran when the Recordatorios
// screen was opened, so a reminder created on the laptop sat in the phone's
// store unscheduled until someone happened to visit that screen. The promise —
// the notification you get on your computer is the one you get on your phone —
// was true about the data and false about the notification, which is the only
// half a person experiences.
//
// Kept as a plain function so it can be tested without a graph, a scheduler or
// a notification service, and so the sync layer does not have to import the
// reminders feature to know what to do after a pass.
library;

import 'sync_pass.dart';

/// Run the follow-up work for a completed pass.
///
/// [rearm] is invoked only when the pass SUCCEEDED and actually applied rows.
/// Rescheduling on every idle tick would cancel and recreate every pending
/// notification twice a minute, which on Android is how a reminder quietly
/// stops arriving.
Future<void> runAfterSyncPass(
  SyncPassReport report, {
  required Future<void> Function() rearm,
}) async {
  if (report.failure != null || report.applied == 0) return;
  try {
    await rearm();
  } catch (_) {
    // Best-effort, like every other notification path here: denied permission,
    // a test host, a desktop with no notification service. Losing the pass's
    // report because an alarm could not be scheduled would trade something
    // that matters for something that does not.
  }
}
