// The two `vpn-gated-backups` spec scenarios that were true only
// STRUCTURALLY — nothing failed if someone gave the gate a second opinion:
//
//   * "Home Wi-Fi with the engine reachable on the LAN is not treated as VPN"
//   * "An unrelated commercial VPN being active does not satisfy the gate"
//
// Both are exactly the case where a naive VPN check answers confidently and
// wrongly: the phone HAS a working network, and in the commercial-VPN case
// the OS would even report `TRANSPORT_VPN` true. The only thing that
// distinguishes them from the real tunnel is that the VPN-ONLY address does
// not answer — so these tests drive the whole production path
// (probe -> VpnGate -> runAutomaticBackupTask) on a network where everything
// else is reachable, and assert no backup runs.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/reachability_vpn_probe.dart';
import 'package:lifeos/core/connectivity/vpn_gate.dart';
import 'package:lifeos/features/backup/domain/backup_host_config.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_outcome.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_runner.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_status.dart';

/// A network where the LAN answers and the VPN-only address does not.
///
/// Any request to a `10.66.66.*` address fails the way an unrouted private
/// address does; EVERYTHING ELSE answers 200. That asymmetry is the point: if
/// the gate ever consults a second address (the paired engine on the LAN, a
/// captive-portal check, anything), this adapter will happily answer it and
/// the assertions below break.
class _LanAnswersVpnDoesNot implements HttpClientAdapter {
  final List<Uri> seen = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.uri);
    if (options.uri.host.startsWith('10.66.66.')) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException('No route to host'),
      );
    }
    return ResponseBody.fromString(
      '{"service":"lifeos-engine","version":1}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AutomaticBackupDeps _deps({
  required Future<VpnGateResult> Function() checkVpn,
  required List<AutomaticBackupStatus> recorded,
  required List<BackupHostConfig> ran,
}) =>
    AutomaticBackupDeps(
      isEnabled: () async => true,
      checkVpn: checkVpn,
      loadConfig: () async => const BackupHostConfig(
        baseUrl: 'http://10.66.66.1:8099',
        accessKey: 'k',
      ),
      isOnUnmeteredNetwork: () async => true,
      loadPassphrase: () async => 'correct horse battery staple',
      runBackup: (config, _) async => ran.add(config),
      recordStatus: (status) async => recorded.add(status),
      notifyUndetermined: () async {},
      now: () => DateTime(2026, 8, 7, 9),
    );

void main() {
  group('home Wi-Fi with the engine reachable on the LAN (spec scenario)', () {
    test('is not treated as VPN — the gate reads offVpn', () async {
      final adapter = _LanAnswersVpnDoesNot();
      final gate = VpnGate(
        probe: ReachabilityVpnProbe(dio: Dio()..httpClientAdapter = adapter),
        operatingSystem: 'android',
      );

      expect(await gate.check(), VpnGateResult.offVpn);
      // The ONLY address consulted is the VPN-only one. A future
      // engine-reachability fallback would show up here as a second host.
      expect(adapter.seen.map((uri) => uri.host).toSet(), {'10.66.66.1'});
    });

    test('no backup runs, and the skip is recorded as an ordinary VPN-down '
        'wait, not as success', () async {
      final adapter = _LanAnswersVpnDoesNot();
      final gate = VpnGate(
        probe: ReachabilityVpnProbe(dio: Dio()..httpClientAdapter = adapter),
        operatingSystem: 'android',
      );
      final recorded = <AutomaticBackupStatus>[];
      final ran = <BackupHostConfig>[];

      final ok = await runAutomaticBackupTask(
        _deps(checkVpn: gate.check, recorded: recorded, ran: ran),
      );

      expect(ok, isTrue);
      expect(ran, isEmpty, reason: 'the spec THEN: the backup MUST NOT run');
      expect(recorded.single.outcome, AutomaticBackupOutcome.skippedVpnDown);
    });
  });

  group('an unrelated commercial VPN is active (spec scenario)', () {
    test('does not satisfy the gate — reachability of OUR address is the only '
        'signal, so no backup runs', () async {
      // A commercial VPN gives the device a working, tunnelled network: the
      // OS reports `NetworkCapabilities.TRANSPORT_VPN` true and general
      // traffic flows (this adapter answers everything). What it cannot do is
      // put `10.66.66.1` on the other end. A transport-class check would say
      // "on VPN" here; this one must not.
      final adapter = _LanAnswersVpnDoesNot();
      final gate = VpnGate(
        probe: ReachabilityVpnProbe(dio: Dio()..httpClientAdapter = adapter),
        operatingSystem: 'android',
      );
      final recorded = <AutomaticBackupStatus>[];
      final ran = <BackupHostConfig>[];

      await runAutomaticBackupTask(
        _deps(checkVpn: gate.check, recorded: recorded, ran: ran),
      );

      expect(ran, isEmpty);
      expect(recorded.single.outcome, AutomaticBackupOutcome.skippedVpnDown);
    });

    test('the transport-class signal is absent from the whole path — the '
        'deliberate omission is pinned, not just documented', () {
      // `operatingSystem` exists as the seam task 2.7 would attach an
      // optional TRANSPORT_VPN PRE-check to. The moment it does, the spec
      // scenario above needs this guard: a transport-class signal must never
      // become a way to SATISFY the gate, and `connectivity_plus` must not
      // quietly appear on the path.
      final sources = <String, String>{
        for (final path in const [
          'lib/core/connectivity/vpn_gate.dart',
          'lib/core/connectivity/reachability_vpn_probe.dart',
          'lib/features/backups/domain/automatic_backup_runner.dart',
        ])
          path: File(path).readAsStringSync(),
      };

      // Positive control: a wrong path or an empty read would make every
      // "does not contain" assertion below pass vacuously.
      expect(sources['lib/core/connectivity/vpn_gate.dart'],
          contains('class VpnGate'));
      expect(sources['lib/core/connectivity/reachability_vpn_probe.dart'],
          contains('class ReachabilityVpnProbe'));
      expect(sources['lib/features/backups/domain/automatic_backup_runner.dart'],
          contains('runAutomaticBackupTask'));

      for (final entry in sources.entries) {
        final code = entry.value
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        expect(code, isNot(contains('connectivity_plus')), reason: entry.key);
        expect(code, isNot(contains('TRANSPORT_VPN')), reason: entry.key);
      }

      expect(File('pubspec.yaml').readAsStringSync(),
          isNot(contains('connectivity_plus:')),
          reason: 'the dependency itself is not on the project');
    });
  });
}
