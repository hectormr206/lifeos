import '../../../core/connectivity/vpn_gate.dart';
import '../../../core/network/heavy_download_policy.dart';
import '../../backup/domain/backup_host_config.dart';
import 'automatic_backup_outcome.dart';
import 'automatic_backup_status.dart';

/// Everything the headless "respaldo automático" WorkManager task needs —
/// mirrors [BriefingBackgroundDeps]'s shape: a MINIMAL, fully injectable
/// service graph (closures, not concrete classes) so [runAutomaticBackupTask]
/// is unit-testable with fakes, no plugin channel, no real VPN.
class AutomaticBackupDeps {
  const AutomaticBackupDeps({
    required this.isEnabled,
    required this.checkVpn,
    required this.loadConfig,
    required this.isOnUnmeteredNetwork,
    required this.loadPassphrase,
    required this.runBackup,
    required this.recordStatus,
    required this.notifyUndetermined,
    required this.now,
  });

  /// Rule: the user's opt-out persists and is honored "regardless of VPN
  /// state" — checked FIRST, before the VPN gate or any network call.
  final Future<bool> Function() isEnabled;

  /// Result of [VpnGate.check] — a closure rather than the concrete class so
  /// tests need no fake probe/dio.
  final Future<VpnGateResult> Function() checkVpn;

  final Future<BackupHostConfig> Function() loadConfig;

  /// Whether the device is currently on an unmetered (Wi-Fi) connection.
  /// Composed with [kHeavyDownloadsRequireWiFi] — this feature OBEYS the
  /// app-wide automatic-heavy-transfer rule, it does not restate it.
  final Future<bool> Function() isOnUnmeteredNetwork;

  /// Reads the sealing passphrase from secure storage
  /// (`AutomaticBackupPassphraseStore`, owner decision on 3.9 — see that
  /// class's doc for why caching it on-device is safe here even though the
  /// MANUAL flow never persists it). A null return (nothing stored) and a
  /// thrown exception (storage backend unavailable, e.g. no Linux keyring)
  /// are treated identically by the runner: either way there is no
  /// passphrase to seal with, so the backup must not be attempted.
  final Future<String?> Function() loadPassphrase;

  /// Performs the actual seal+upload with the given passphrase. Throws on
  /// any failure — including the VPN dropping mid-upload, which surfaces
  /// through the SAME exception path as an ordinary connection failure
  /// (`BackupHostClient.upload`). A backup that did not land must never be
  /// mistaken for one that did.
  final Future<void> Function(BackupHostConfig config, String passphrase)
      runBackup;

  final Future<void> Function(AutomaticBackupStatus status) recordStatus;

  /// LOUD surfacing for [AutomaticBackupOutcome.skippedVpnUnknown] — a status
  /// row alone is not enough per the repo's fail-loudly rule (an ordinary
  /// skip is silent-ish; an undetermined check is not).
  final Future<void> Function() notifyUndetermined;

  final DateTime Function() now;
}

/// Headless VPN-gated automatic backup — the WorkManager task body.
///
/// Order matters and mirrors the spec: the user's opt-out first (never even
/// touches the VPN gate when disabled), then the VPN gate itself (`unknown`
/// is NEVER treated as permission), then the Wi-Fi/unmetered policy for the
/// heavy payload, then the sealing passphrase (secure-storage read failure
/// or absence recorded as its own [AutomaticBackupOutcome.passphraseUnavailable],
/// never silently skipped), and only then the upload — whose own failure
/// (including a mid-upload VPN loss) is caught and recorded as
/// [AutomaticBackupOutcome.failed], never success. Always returns `true`:
/// like the briefing scheduler, WorkManager must never retry-loop this task
/// — an unrecorded retry would be invisible, and the recorded status is the
/// real backstop.
Future<bool> runAutomaticBackupTask(AutomaticBackupDeps deps) async {
  final at = deps.now();

  if (!await deps.isEnabled()) {
    await deps.recordStatus(
      AutomaticBackupStatus(outcome: AutomaticBackupOutcome.skippedDisabled, at: at),
    );
    return true;
  }

  final VpnGateResult vpn;
  try {
    vpn = await deps.checkVpn();
  } catch (_) {
    // The gate failing to run at all makes the same claim as `unknown`: an
    // uncertain check is not permission.
    await _skipUndetermined(deps, at);
    return true;
  }

  switch (vpn) {
    case VpnGateResult.unknown:
      await _skipUndetermined(deps, at);
      return true;
    case VpnGateResult.offVpn:
      await deps.recordStatus(
        AutomaticBackupStatus(outcome: AutomaticBackupOutcome.skippedVpnDown, at: at),
      );
      return true;
    case VpnGateResult.onVpn:
      break;
  }

  if (kHeavyDownloadsRequireWiFi && !await deps.isOnUnmeteredNetwork()) {
    await deps.recordStatus(
      AutomaticBackupStatus(outcome: AutomaticBackupOutcome.waitingForWifi, at: at),
    );
    return true;
  }

  String? passphrase;
  try {
    passphrase = await deps.loadPassphrase();
  } catch (_) {
    // Storage backend unavailable (e.g. no Linux keyring) reads the same as
    // "nothing stored" to this runner — both mean there is no passphrase to
    // seal with, never a reason to crash the task.
    passphrase = null;
  }
  if (passphrase == null || passphrase.isEmpty) {
    await deps.recordStatus(
      AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.passphraseUnavailable,
        at: at,
      ),
    );
    return true;
  }

  try {
    final config = await deps.loadConfig();
    await deps.runBackup(config, passphrase);
    await deps.recordStatus(
      AutomaticBackupStatus(outcome: AutomaticBackupOutcome.succeeded, at: at),
    );
  } catch (error) {
    await deps.recordStatus(
      AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.failed,
        at: at,
        message: '$error',
      ),
    );
  }
  return true;
}

Future<void> _skipUndetermined(AutomaticBackupDeps deps, DateTime at) async {
  await deps.recordStatus(
    AutomaticBackupStatus(outcome: AutomaticBackupOutcome.skippedVpnUnknown, at: at),
  );
  try {
    await deps.notifyUndetermined();
  } catch (_) {
    // Best-effort, same contract as every notifier in this app — the status
    // row recorded above is the floor even if the OS notification fails.
  }
}
