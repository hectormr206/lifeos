// A reminder created on the laptop has to ring on the phone.
//
// Reminders live in the synced graph, so the ROW arrives on every device by
// itself. The alarm does not: `reschedulePending` was only ever called from
// the Recordatorios screen's notifier, so a reminder that arrived by sync sat
// in the store unscheduled until someone happened to open that screen.
//
// Which makes the promise — "la notificación que te llegue a tu ordenador es
// la misma que te llegará al android" — true about the DATA and false about
// the notification, the only half the user experiences.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/data/sync_after_pass.dart';

void main() {
  SyncPassReport report({int applied = 0, bool ok = true}) => SyncPassReport(
        received: applied,
        applied: applied,
        sent: 0,
        conflicts: 0,
        failure: ok ? null : 'boom',
      );

  test('rows arriving rearm the alarms', () async {
    var rearmed = 0;
    await runAfterSyncPass(report(applied: 3), rearm: () async => rearmed++);

    expect(rearmed, 1);
  });

  test('a pass that changed nothing does not touch the alarms', () async {
    // Rescheduling on every idle tick would cancel and re-create every
    // pending notification twice a minute, which on Android is how a reminder
    // quietly stops arriving.
    var rearmed = 0;
    await runAfterSyncPass(report(), rearm: () async => rearmed++);

    expect(rearmed, 0);
  });

  test('a failed pass rearms nothing', () async {
    var rearmed = 0;
    await runAfterSyncPass(
      report(applied: 5, ok: false),
      rearm: () async => rearmed++,
    );

    expect(rearmed, 0);
  });

  test('a rearm that throws never breaks the sync pass', () async {
    // The alarm is best-effort — denied permission, a test host, a desktop
    // with no notification service. Losing the sync report because a
    // notification could not be scheduled would trade something that matters
    // for something that does not.
    await expectLater(
      runAfterSyncPass(report(applied: 1), rearm: () async => throw 'nope'),
      completes,
    );
  });
}
