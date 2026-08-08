/// Did the update the app asked for actually happen?
///
/// THE DEFECT THIS REPLACES. `_requestDesktopUpdate` used to set a flag the
/// instant the trigger file was created, and the screen printed:
///
///   "Actualización solicitada. El sistema la instala en segundo plano; se
///    aplica la próxima vez que abras LifeOS."
///
/// stated as fact. On the real laptop the update failed twice in a row — HTTP
/// 403 from the manifest, no access key saved in `/etc/lifeos/update.env` — and
/// the app showed that same green confirmation both times. The user pressed the
/// button, was told it was handled, and nothing happened. A REQUEST was
/// presented as a RESULT.
///
/// WHAT THE APP CAN HONESTLY OBSERVE. It runs unprivileged and cannot read the
/// journal, so the updater's reason for failing is out of reach and is
/// therefore never claimed. Two things ARE observable, and this watcher is
/// built out of exactly those:
///
///   1. The installed release on disk. `install-linux.sh` rewrites
///      `/opt/lifeos/manifest.json` and repoints `current` only after the new
///      release is fully staged; every failure path aborts BEFORE that swap. So
///      a changed versionCode is proof of a successful install, and an
///      unchanged one is proof that nothing landed.
///   2. Whether the trigger file is still there. `lifeos-updater.path` consumes
///      it when it fires. Still present after a few seconds means nothing is
///      watching — the units are not installed or not running. That is a
///      DIFFERENT failure with a DIFFERENT fix than "the update ran and
///      failed", so it gets its own verdict instead of being folded into a
///      generic timeout.
///
/// Everything else stays unsaid. "No pude confirmar que se aplicara" plus the
/// version still installed is honest; "instalada correctamente" was not.
library;

import 'package:flutter/foundation.dart';

import 'desktop_update_trigger.dart';
import 'installed_release.dart';

/// The three things the app can prove about a requested desktop update.
enum DesktopUpdateOutcomeKind {
  /// The installed versionCode really went up. The only success.
  applied,

  /// The trigger file was never consumed: nothing is watching it.
  notWatched,

  /// The trigger was consumed but the installed version never changed within
  /// the bounded wait. The app does NOT know why, and does not guess.
  notApplied,
}

@immutable
class DesktopUpdateOutcome {
  const DesktopUpdateOutcome._(this.kind, this.release);

  /// The new release, for [DesktopUpdateOutcomeKind.applied].
  factory DesktopUpdateOutcome.applied(InstalledRelease release) =>
      DesktopUpdateOutcome._(DesktopUpdateOutcomeKind.applied, release);

  /// [release] is what is STILL installed — naming it is what makes the
  /// failure message actionable instead of merely negative.
  factory DesktopUpdateOutcome.notWatched(InstalledRelease? release) =>
      DesktopUpdateOutcome._(DesktopUpdateOutcomeKind.notWatched, release);

  factory DesktopUpdateOutcome.notApplied(InstalledRelease? release) =>
      DesktopUpdateOutcome._(DesktopUpdateOutcomeKind.notApplied, release);

  final DesktopUpdateOutcomeKind kind;

  /// The release the outcome is about: the NEW one when applied, the one still
  /// installed otherwise. Null only when the disk could not be read at all.
  final InstalledRelease? release;

  bool get applied => kind == DesktopUpdateOutcomeKind.applied;
}

/// Watches for the outcome of a requested desktop update. A port so the
/// notifier can be driven without a clock, a disk or a systemd.
abstract class DesktopUpdateWatcher {
  /// Wait — for a BOUNDED period — for [baseline] to be replaced on disk.
  Future<DesktopUpdateOutcome> awaitOutcome(InstalledRelease? baseline);
}

Future<void> _wallClockSleep(Duration d) => Future<void>.delayed(d);

/// The real watcher: polls the disk and the trigger file.
///
/// Polling rather than a filesystem watch on purpose. The installer replaces
/// `manifest.json` by `cp` and swaps `current` by `rename`, and inotify
/// semantics across those two differ per filesystem; a poll every couple of
/// seconds for a few minutes costs nothing and cannot miss the transition.
class PollingDesktopUpdateWatcher implements DesktopUpdateWatcher {
  const PollingDesktopUpdateWatcher({
    required this.reader,
    required this.trigger,
    this.pollInterval = const Duration(seconds: 2),
    this.watcherGrace = const Duration(seconds: 6),
    this.timeout = const Duration(minutes: 5),
    this.sleep = _wallClockSleep,
  });

  final InstalledReleaseReader reader;
  final DesktopUpdateTrigger trigger;

  /// Injected so the watcher's sense of time is testable without a wall clock:
  /// a five-minute timeout must be provable in milliseconds.
  final Future<void> Function(Duration) sleep;

  /// How often the disk is re-read.
  final Duration pollInterval;

  /// How long a still-present trigger file is tolerated before concluding that
  /// nothing is watching it. Short by design: the `.path` unit fires within
  /// milliseconds of the file appearing, so seconds is already generous, and
  /// making the user wait out the full timeout for a verdict we can reach in
  /// six seconds would be its own small cruelty.
  final Duration watcherGrace;

  /// The hard bound on the whole wait. A ~150 MB download over a slow link is
  /// the case this has to cover; past it the app says it could not confirm,
  /// which stays true even if the update lands a minute later (the next launch
  /// will simply show the new version).
  final Duration timeout;

  @override
  Future<DesktopUpdateOutcome> awaitOutcome(InstalledRelease? baseline) async {
    var elapsed = Duration.zero;
    var consumed = false;
    InstalledRelease? latest = baseline;

    while (elapsed < timeout) {
      await sleep(pollInterval);
      elapsed += pollInterval;

      final current = await reader.read();
      if (current != null) latest = current;
      // The disk is checked FIRST every round. A trigger file that lingers is
      // only ever a reason to give up EARLY; it can never override the fact
      // that the new release is already installed.
      if (_isUpgrade(baseline: baseline, current: current)) {
        return DesktopUpdateOutcome.applied(current!);
      }

      if (!consumed) {
        if (!await _isPending()) {
          consumed = true;
        } else if (elapsed >= watcherGrace) {
          return DesktopUpdateOutcome.notWatched(latest);
        }
      }
    }
    return DesktopUpdateOutcome.notApplied(latest);
  }

  /// Only a strictly higher versionCode counts.
  ///
  /// With no [baseline] there is nothing to compare against, so "applied" is
  /// unprovable and is not claimed — an unreadable `/opt/lifeos` degrades to
  /// "could not confirm", never to a false success. A DOWNgrade is not an
  /// upgrade either: `install-linux.sh` refuses to go backwards, so seeing a
  /// lower code means we are reading something other than a completed install.
  bool _isUpgrade({
    required InstalledRelease? baseline,
    required InstalledRelease? current,
  }) =>
      baseline != null &&
      current != null &&
      current.versionCode > baseline.versionCode;

  Future<bool> _isPending() async {
    try {
      return await trigger.isRequestPending();
    } catch (_) {
      // Cannot tell → do not accuse the system of not watching. The timeout
      // path still reports honestly.
      return false;
    }
  }
}
