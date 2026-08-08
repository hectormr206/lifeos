import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/network/heavy_download_policy.dart';

/// The `taskName` WorkManager hands back to the callback dispatcher.
const String automaticBackupTaskName = 'automatic_backup_vpn_gated';

/// The unique WorkManager periodic-work name.
const String automaticBackupUniqueWorkName = 'lifeos_automatic_backup_periodic';

/// THE SCHEDULER INTERVAL — NOT MEASURED.
///
/// Task 2.8 ("measure real reachability-probe latency on-VPN and off-VPN
/// timeout behavior on a Pixel device") has NOT been run — no device was
/// available in this session (see design.md Open Questions). This value is a
/// CONSERVATIVE placeholder, not a measurement: six hours keeps the probe's
/// network/battery cost low (worst case a handful of ~2s-bounded failed
/// probes a day when off-VPN) while still catching a typical home-VPN window
/// within the day. IT IS AN ESTIMATE. It is expected to be tightened once
/// task 2.8's real numbers land — see the pinning test
/// (`workmanager_automatic_backup_work_test.dart`), which forces this change
/// to be deliberate rather than an incidental edit.
const Duration kAutomaticBackupPollInterval = Duration(hours: 6);

/// THE NETWORK CONSTRAINT THE TASK IS REGISTERED UNDER — and therefore the
/// only place the Wi-Fi-only rule for this heavy payload is actually enforced.
///
/// It is an OS guarantee (the same mechanism `DownloadTask.requiresWiFi`
/// uses): WorkManager holds the task until the constraint is satisfied, so
/// off Wi-Fi the task does not fire at all rather than firing and deciding.
/// Composed from [kHeavyDownloadsRequireWiFi] rather than hardcoded, so this
/// registration follows the shared policy instead of restating it, and named
/// rather than inlined so [unmeteredGuaranteedByRegistration] can derive from
/// the SAME value instead of asserting it independently.
const NetworkType automaticBackupNetworkType = kHeavyDownloadsRequireWiFi
    ? NetworkType.unmetered
    : NetworkType.connected;

/// NOT A NETWORK CHECK — the registration guarantee above, read back.
///
/// [AutomaticBackupDeps.isOnUnmeteredNetwork] exists so `scheduler_test.dart`
/// can drive both branches of the runner's Wi-Fi decision; in production that
/// branch is unreachable, because WorkManager will not start a task whose
/// [automaticBackupNetworkType] constraint is unmet. What this returns is
/// therefore a restatement of the constraint, and it is DERIVED from it: flip
/// [automaticBackupNetworkType] to [NetworkType.connected] and this stops
/// claiming Wi-Fi (the runner then records `waitingForWifi` — visible and
/// safe) instead of an `() async => true` that reads like a real check and is
/// not one.
Future<bool> unmeteredGuaranteedByRegistration() async =>
    automaticBackupNetworkType == NetworkType.unmetered;

/// Signature of the failure sink — same shape and default as
/// `core/tray/tray_service.dart`'s [TrayErrorReporter], for the same reason:
/// injected in tests so a deliberate failure does not pollute the console.
typedef AutomaticBackupSchedulerErrorReporter = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Registers/cancels the periodic automatic-backup task.
///
/// Mirrors [WorkmanagerBriefingBackgroundWork]'s shape and its best-effort
/// contract — an absent plugin channel (tests) or an OS refusal must never
/// throw at the caller. "Best-effort" is NOT "silent", though: a registration
/// that never lands means automatic backups never run, and nothing else in
/// the system would ever notice. So both methods REPORT the failure and
/// return whether the operation actually landed, and the settings screen
/// refuses to leave the switch reading "on" over a registration that failed.
class WorkmanagerAutomaticBackupWork {
  WorkmanagerAutomaticBackupWork({
    Workmanager? workmanager,
    AutomaticBackupSchedulerErrorReporter? reportError,
  })  : _workmanager = workmanager ?? Workmanager(),
        _reportError = reportError ?? _defaultReportError;

  final Workmanager _workmanager;
  final AutomaticBackupSchedulerErrorReporter _reportError;

  /// True when WorkManager accepted the registration. False means automatic
  /// backups are NOT scheduled — the caller must surface that.
  Future<bool> schedule() async {
    try {
      await _workmanager.registerPeriodicTask(
        automaticBackupUniqueWorkName,
        automaticBackupTaskName,
        frequency: kAutomaticBackupPollInterval,
        constraints: Constraints(networkType: automaticBackupNetworkType),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }

  /// True when the cancellation landed. A false here is far less dangerous
  /// than a false from [schedule] — the runner checks the user's opt-out
  /// FIRST and records `skippedDisabled` — but it is still a scheduler
  /// instruction the OS did not take, so it is reported rather than dropped.
  Future<bool> cancel() async {
    try {
      await _workmanager.cancelByUniqueName(automaticBackupUniqueWorkName);
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }

  static void _defaultReportError(Object error, StackTrace stackTrace) {
    debugPrint('LifeOS automatic-backup scheduling failed: $error');
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'lifeos/features/backups',
        context: ErrorDescription(
          'registering or cancelling the periodic automatic-backup task',
        ),
      ),
    );
  }
}
