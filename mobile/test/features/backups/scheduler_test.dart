// Proves the VPN-gated automatic backup scheduler's decision table: run only
// on a PROVEN VPN (never on `unknown`), skip visibly off-VPN, skip LOUDLY on
// `unknown`, wait for Wi-Fi under the heavy-download policy, abort a
// mid-backup VPN loss as a defined failure (never a silent partial success),
// and respect the user's opt-out — checked BEFORE any network call.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/vpn_gate.dart';
import 'package:lifeos/features/backup/domain/backup_host_config.dart';
import 'package:lifeos/features/backup/domain/backup_host_diagnosis.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_outcome.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_runner.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_status.dart';

AutomaticBackupDeps _deps({
  bool enabled = true,
  Future<VpnGateResult> Function()? checkVpn,
  bool onWifi = true,
  Future<String?> Function()? loadPassphrase,
  Future<void> Function(BackupHostConfig, String)? runBackup,
  required List<AutomaticBackupStatus> recorded,
  List<int>? notifyCount,
}) {
  final notifications = notifyCount ?? <int>[0];
  return AutomaticBackupDeps(
    isEnabled: () async => enabled,
    checkVpn: checkVpn ?? () async => VpnGateResult.onVpn,
    loadConfig: () async => const BackupHostConfig(
      baseUrl: 'http://10.66.66.1:8099',
      accessKey: 'k',
    ),
    isOnUnmeteredNetwork: () async => onWifi,
    loadPassphrase: loadPassphrase ?? () async => 'correct horse battery staple',
    runBackup: runBackup ?? (_, unused) async {},
    recordStatus: (status) async => recorded.add(status),
    notifyUndetermined: () async => notifications[0]++,
    now: () => DateTime(2026, 7, 30, 9),
  );
}

void main() {
  test('onVpn + unmetered → backup runs, with the stored passphrase',
      () async {
    final ran = <BackupHostConfig>[];
    final usedPassphrases = <String>[];
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      runBackup: (config, passphrase) async {
        ran.add(config);
        usedPassphrases.add(passphrase);
      },
      recorded: recorded,
    );

    final ok = await runAutomaticBackupTask(deps);

    expect(ok, isTrue);
    expect(ran, hasLength(1));
    expect(usedPassphrases.single, 'correct horse battery staple');
    expect(recorded.single.outcome, AutomaticBackupOutcome.succeeded);
  });

  test('offVpn → backup skipped, visible status row (not just log)', () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      checkVpn: () async => VpnGateResult.offVpn,
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
    );

    await runAutomaticBackupTask(deps);

    expect(ran, isEmpty);
    expect(recorded.single.outcome, AutomaticBackupOutcome.skippedVpnDown);
  });

  test('unknown → skipped + loud notification + status surfaced', () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    final notifications = <int>[0];
    final deps = _deps(
      checkVpn: () async => VpnGateResult.unknown,
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
      notifyCount: notifications,
    );

    await runAutomaticBackupTask(deps);

    expect(ran, isEmpty, reason: 'unknown must NEVER be treated as onVpn');
    expect(recorded.single.outcome, AutomaticBackupOutcome.skippedVpnUnknown);
    expect(notifications[0], 1);
  });

  test('VPN goes offVpn mid-backup → aborted, recorded failed, never success',
      () async {
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      runBackup: (_, unused) async => throw const BackupHostException(
        BackupHostState.unreachable,
        'Se cortó la conexión con el servidor. El respaldo NO se guardó.',
      ),
      recorded: recorded,
    );

    await runAutomaticBackupTask(deps);

    expect(recorded.single.outcome, AutomaticBackupOutcome.failed);
    expect(recorded.single.outcome, isNot(AutomaticBackupOutcome.succeeded));
    expect(recorded.single.message, contains('NO se guardó'));
  });

  test('onVpn but off Wi-Fi with heavy payload → waits per heavy_download_policy',
      () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      onWifi: false,
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
    );

    await runAutomaticBackupTask(deps);

    expect(ran, isEmpty);
    expect(recorded.single.outcome, AutomaticBackupOutcome.waitingForWifi);
  });

  test('user disables automatic backups → no run regardless of VPN state',
      () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    var vpnChecked = false;
    final deps = _deps(
      enabled: false,
      checkVpn: () async {
        vpnChecked = true;
        return VpnGateResult.onVpn;
      },
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
    );

    await runAutomaticBackupTask(deps);

    expect(ran, isEmpty);
    expect(vpnChecked, isFalse,
        reason: 'disabled is checked BEFORE any network call, including the VPN gate');
    expect(recorded.single.outcome, AutomaticBackupOutcome.skippedDisabled);
  });

  test('no passphrase in secure storage → distinct outcome, backup never attempted',
      () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      loadPassphrase: () async => null,
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
    );

    await runAutomaticBackupTask(deps);

    expect(ran, isEmpty);
    expect(recorded.single.outcome, AutomaticBackupOutcome.passphraseUnavailable);
    expect(recorded.single.outcome, isNot(AutomaticBackupOutcome.skippedVpnDown));
    expect(recorded.single.outcome, isNot(AutomaticBackupOutcome.failed));
  });

  test('secure storage throws reading the passphrase → same distinct outcome, never crashes',
      () async {
    final ran = <BackupHostConfig>[];
    final recorded = <AutomaticBackupStatus>[];
    final deps = _deps(
      loadPassphrase: () async => throw Exception('no Secret Service provider'),
      runBackup: (config, _) async => ran.add(config),
      recorded: recorded,
    );

    final ok = await runAutomaticBackupTask(deps);

    expect(ok, isTrue);
    expect(ran, isEmpty);
    expect(recorded.single.outcome, AutomaticBackupOutcome.passphraseUnavailable);
  });
}
