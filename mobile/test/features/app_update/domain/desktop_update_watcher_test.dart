// The app asked systemd for an update. Did it happen?
//
// THE DEFECT THIS EXISTS FOR. Before this, requesting the update printed
// "Actualización solicitada… se aplica la próxima vez que abras LifeOS" and
// stopped there. On the real laptop the update failed twice in a row (HTTP 403
// from the manifest, no access key saved) and the app showed that same green
// confirmation both times. A request was presented as a result.
//
// The app cannot read the journal (root) and cannot see the updater's exit
// code. What it CAN observe is exactly two things, and this watcher is built
// out of only those:
//
//   * the installed release on disk (`/opt/lifeos/manifest.json`), which the
//     installer rewrites on success and never touches on failure;
//   * the trigger file, which the `.path` unit consumes when it fires. Still
//     sitting there after a few seconds means nothing is watching it at all —
//     a different failure, with a different fix, and worth telling apart.
//
// Anything else — WHY the update failed — is not observable here and is
// therefore not claimed.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_trigger.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_watcher.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';

/// A disk that answers whatever the test scripted, one poll at a time.
class _ScriptedReader implements InstalledReleaseReader {
  _ScriptedReader(this._answers);

  final List<InstalledRelease?> _answers;
  int reads = 0;

  @override
  Future<InstalledRelease?> read() async {
    final answer = _answers[reads.clamp(0, _answers.length - 1)];
    reads++;
    return answer;
  }
}

class _ScriptedTrigger implements DesktopUpdateTrigger {
  _ScriptedTrigger({this.pending = false});

  /// Whether the trigger file is still sitting there unconsumed.
  bool pending;
  int requests = 0;

  @override
  Future<void> requestUpdate() async => requests++;

  @override
  Future<bool> isRequestPending() async => pending;
}

const _installed = InstalledRelease(versionCode: 773, versionName: '0.9.17');
const _updated = InstalledRelease(versionCode: 793, versionName: '0.9.21');

PollingDesktopUpdateWatcher _watcher({
  required InstalledReleaseReader reader,
  required DesktopUpdateTrigger trigger,
  Duration timeout = const Duration(seconds: 20),
  Duration watcherGrace = const Duration(seconds: 6),
  List<Duration>? slept,
}) =>
    PollingDesktopUpdateWatcher(
      reader: reader,
      trigger: trigger,
      pollInterval: const Duration(seconds: 2),
      watcherGrace: watcherGrace,
      timeout: timeout,
      // No wall-clock waiting in tests: the watcher's sense of time is the
      // sequence of sleeps it asks for, and the test records them.
      sleep: (d) async => slept?.add(d),
    );

void main() {
  test('a version that really changed on disk is reported as applied',
      () async {
    final reader = _ScriptedReader([_installed, _installed, _updated]);
    final trigger = _ScriptedTrigger();

    final outcome = await _watcher(reader: reader, trigger: trigger)
        .awaitOutcome(_installed);

    expect(outcome.kind, DesktopUpdateOutcomeKind.applied);
    expect(outcome.release, _updated,
        reason: 'the user is told WHICH version landed, not just "ok"');
  });

  test('a version that never changed is NOT reported as installed', () async {
    // The exact defect: two failed updates, two green confirmations.
    final reader = _ScriptedReader([_installed]);
    final trigger = _ScriptedTrigger(); // consumed straight away

    final outcome = await _watcher(reader: reader, trigger: trigger)
        .awaitOutcome(_installed);

    expect(outcome.kind, DesktopUpdateOutcomeKind.notApplied);
    expect(outcome.release, _installed,
        reason: 'saying which version is STILL installed is the honest answer');
  });

  test('a trigger file nobody consumes means nothing is watching', () async {
    // Distinct from "the update failed": here the .path unit is not installed
    // or not running, so the update was never even attempted.
    final reader = _ScriptedReader([_installed]);
    final trigger = _ScriptedTrigger(pending: true);
    final slept = <Duration>[];

    final outcome = await _watcher(
      reader: reader,
      trigger: trigger,
      watcherGrace: const Duration(seconds: 6),
      timeout: const Duration(minutes: 5),
      slept: slept,
    ).awaitOutcome(_installed);

    expect(outcome.kind, DesktopUpdateOutcomeKind.notWatched);
    expect(slept.fold(Duration.zero, (a, b) => a + b),
        lessThanOrEqualTo(const Duration(seconds: 6)),
        reason: 'no watcher is a verdict in seconds, not a five-minute wait');
  });

  test('a trigger consumed late still yields the applied verdict', () async {
    // The unit fired after the grace window: pending is only ever a reason to
    // give up EARLY, never a reason to override what the disk says.
    final reader = _ScriptedReader([_installed, _updated]);
    final trigger = _ScriptedTrigger(pending: true);

    final outcome = await _watcher(
      reader: reader,
      trigger: trigger,
      watcherGrace: const Duration(minutes: 1),
    ).awaitOutcome(_installed);

    expect(outcome.kind, DesktopUpdateOutcomeKind.applied);
  });

  test('an unreadable disk never counts as an upgrade', () async {
    // Without a baseline there is nothing to compare against, so "applied" is
    // unprovable and must not be claimed.
    final reader = _ScriptedReader([_updated]);
    final trigger = _ScriptedTrigger();

    final outcome =
        await _watcher(reader: reader, trigger: trigger).awaitOutcome(null);

    expect(outcome.kind, DesktopUpdateOutcomeKind.notApplied);
  });

  test('a DOWNGRADE is not an upgrade', () async {
    final reader = _ScriptedReader([_installed]);
    final trigger = _ScriptedTrigger();

    final outcome =
        await _watcher(reader: reader, trigger: trigger).awaitOutcome(_updated);

    expect(outcome.kind, DesktopUpdateOutcomeKind.notApplied);
    expect(outcome.release, _installed);
  });

  test('the wait is bounded — it never polls forever', () async {
    final reader = _ScriptedReader([_installed]);
    final trigger = _ScriptedTrigger();
    final slept = <Duration>[];

    await _watcher(
      reader: reader,
      trigger: trigger,
      timeout: const Duration(seconds: 20),
      slept: slept,
    ).awaitOutcome(_installed);

    expect(slept.fold(Duration.zero, (a, b) => a + b),
        lessThanOrEqualTo(const Duration(seconds: 20)));
  });
}
