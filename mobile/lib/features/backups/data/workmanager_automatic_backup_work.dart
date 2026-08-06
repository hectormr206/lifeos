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

/// Registers/cancels the periodic automatic-backup task.
///
/// Mirrors [WorkmanagerBriefingBackgroundWork]'s shape and its best-effort
/// contract (no plugin channel in tests / OS refusal must never throw). The
/// `unmetered` constraint is HOW the Wi-Fi-only rule for this heavy payload
/// is actually enforced (an OS guarantee, same mechanism `DownloadTask.
/// requiresWiFi` uses) — composed from [kHeavyDownloadsRequireWiFi] rather
/// than hardcoded, so this registration follows the shared policy instead of
/// restating it.
class WorkmanagerAutomaticBackupWork {
  WorkmanagerAutomaticBackupWork({Workmanager? workmanager})
      : _workmanager = workmanager ?? Workmanager();

  final Workmanager _workmanager;

  Future<void> schedule() async {
    try {
      await _workmanager.registerPeriodicTask(
        automaticBackupUniqueWorkName,
        automaticBackupTaskName,
        frequency: kAutomaticBackupPollInterval,
        constraints: Constraints(
          networkType: kHeavyDownloadsRequireWiFi
              ? NetworkType.unmetered
              : NetworkType.connected,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {
      // Best-effort like every scheduler in this app.
    }
  }

  Future<void> cancel() async {
    try {
      await _workmanager.cancelByUniqueName(automaticBackupUniqueWorkName);
    } catch (_) {
      // Best-effort.
    }
  }
}
