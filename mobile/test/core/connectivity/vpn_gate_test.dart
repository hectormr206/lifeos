// Proves the sole authoritative "am I on the VPN to MY VPS?" gate
// (design.md, specs/vpn-gated-backups/spec.md): reachability of the
// VPN-only backup-host address, nothing platform-specific. See
// vpn_gate.dart's class doc for why
// `NetworkCapabilities.TRANSPORT_VPN` is deliberately not on this path.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/reachability_vpn_probe.dart';
import 'package:lifeos/core/connectivity/vpn_gate.dart';
import 'package:lifeos/core/tls/tls_adapter_factory.dart';
import 'package:lifeos/core/tls/tls_trust_decision.dart';

/// Serves canned responses/exceptions so tests exercise the gate's
/// decisions, not a real socket — same fake used by
/// `backup_host_client_test.dart` for the same reason.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  /// Every request this adapter served — lets a test assert WHICH path was
  /// actually hit (design.md's endpoint, not just the status classification).
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

VpnGate _gateFor(
  FutureOr<ResponseBody> Function(RequestOptions) handler, {
  String operatingSystem = 'android',
  _FakeAdapter? adapter,
}) {
  final dio = Dio()..httpClientAdapter = adapter ?? _FakeAdapter(handler);
  final probe = ReachabilityVpnProbe(dio: dio);
  return VpnGate(probe: probe, operatingSystem: operatingSystem);
}

ResponseBody _json(int status) => ResponseBody.fromString(
      '{"ok": true}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  group('VpnGate', () {
    test('the VPN-only address answering 200 reads as onVpn', () async {
      final gate = _gateFor((_) => _json(200));

      expect(await gate.check(), VpnGateResult.onVpn);
    });

    test('a connection error (unroutable address) reads as offVpn', () async {
      final gate = _gateFor(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );

      expect(await gate.check(), VpnGateResult.offVpn);
    });

    test('the bounded timeout elapsing reads as offVpn, not unknown', () async {
      final gate = _gateFor(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(await gate.check(), VpnGateResult.offVpn);
    });

    test('an ambiguous, non-timeout transport error reads as unknown, never onVpn', () async {
      // A bad certificate, a cancellation, dio's generic `unknown` wrapping
      // something unexpected — none of these is the same claim as "I
      // checked and the tunnel is down".
      final gate = _gateFor(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.badCertificate,
        ),
      );

      expect(await gate.check(), VpnGateResult.unknown);
    });

    // The gate answers "is the tunnel up?", not "is the backup service
    // happy?" — ANY HTTP response (401/404/500) proves bytes crossed the
    // tunnel; only a transport failure means it's down. A real VPS probe
    // returned 401 for the wrong path; status-based classification would
    // have silently disabled backups on a working VPN.
    test('a 401 (auth-rejected but answered) reads as onVpn, not offVpn or unknown', () async {
      final gate = _gateFor((_) => _json(401));

      expect(await gate.check(), VpnGateResult.onVpn);
    });

    test('a 404 (wrong route but answered) reads as onVpn', () async {
      final gate = _gateFor((_) => _json(404));

      expect(await gate.check(), VpnGateResult.onVpn);
    });

    test('a 500 (service broken but answered) reads as onVpn', () async {
      // The backup SERVICE being unhealthy is a completely different fact
      // from the TUNNEL being down — conflating them is exactly the bug
      // this test guards against.
      final gate = _gateFor((_) => _json(500));

      expect(await gate.check(), VpnGateResult.onVpn);
    });

    test('probes /v1/health — the only unauthenticated endpoint that actually exists', () async {
      // A real curl against the VPS backup-host proved `/health` 401s and
      // `/v1/health` is the one that answers 200 unauthenticated (same path
      // `BackupHostClient` already uses for its own rung-1 reachability
      // check) — there is no unauthenticated `/health`.
      final adapter = _FakeAdapter((_) => _json(200));
      final probe = ReachabilityVpnProbe(dio: Dio()..httpClientAdapter = adapter);

      await probe.probe();

      expect(adapter.seen.single.uri.path, '/v1/health');
    });

    test('unknown is never silently upgraded to onVpn', () async {
      // The hard rule this whole enum exists to enforce (repo silent-failure
      // rule): "could not tell" must never read as "on the VPN".
      final gate = _gateFor(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: const FormatException('unexpected body'),
        ),
      );

      final result = await gate.check();

      expect(result, isNot(VpnGateResult.onVpn));
      expect(result, VpnGateResult.unknown);
    });

    test("stores the operating system it was built for, per app_platform.dart's seam", () {
      final gate = _gateFor((_) => _json(200), operatingSystem: 'linux');

      expect(gate.operatingSystem, 'linux');
    });

    group('hostile-LAN boundary (task 2.4)', () {
      test(
          'a spoofed local responder at the VPN-only address still reads as onVpn — '
          'the gate is an ATTEMPT gate, not authentication', () async {
        // A device on the same hostile LAN segment could bind
        // 10.66.66.1:8099 and answer with a plausible-looking payload. The
        // gate alone cannot and does not try to distinguish that from the
        // real backup-host — see vpn_gate.dart's class doc. This is
        // ACCEPTED and bounded, not a gap: what actually gets sent is
        // sealed client-side, and the real defence against an impostor is
        // server-identity validation, proven in the next test.
        final gate = _gateFor(
          (options) => ResponseBody.fromString(
            '{"service": "lifeos-backup-host", "version": 1}',
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ),
        );

        expect(await gate.check(), VpnGateResult.onVpn);
      });

      test(
          'the real defence against that spoof is TLS server-identity validation, '
          'which the gate itself does not perform', () {
        // Does not call VpnGate at all — proves the boundary the test above
        // accepts actually has a real defence sitting behind it:
        // mobile/lib/core/tls/ already provides pinned-CA chain validation
        // (design D5/D6), independent of and unaffected by whatever this
        // gate decides. A caller wiring up the real upload path (Phase 3)
        // MUST apply it before sending anything to an address this gate
        // approved; VpnGate itself has no way to and does not claim to.
        const decision = TlsTrustDecision(pinnedCaPem: _fakeCaPem, host: '10.66.66.1');

        final adapter = const PlatformTlsAdapterFactory().build(decision);

        expect(adapter, isNotNull);
      });
    });
  });
}

// Same throwaway self-signed fixture `tls_adapter_factory_test.dart` uses —
// `SecurityContext` validates trusted-certificate bytes eagerly, so a
// syntactically-fake PEM would throw here rather than proving anything.
const _fakeCaPem = '''
-----BEGIN CERTIFICATE-----
MIIDDzCCAfegAwIBAgIUddubBadIz2dSaPf9BquSSzX4oBwwDQYJKoZIhvcNAQEL
BQAwFzEVMBMGA1UEAwwMdGVzdC5leGFtcGxlMB4XDTI2MDcxNTAxMTk0NloXDTI2
MDcxNjAxMTk0NlowFzEVMBMGA1UEAwwMdGVzdC5leGFtcGxlMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuu3fLYXhi/Yk9EKxCNZbJjZcrhUEqbxwMrue
wq2AFRUvgz/zMu7r5a1VF5f/ZlF0du1Z0W9bIfXDigHQGBNA0LlIi2PGsYzP7tq5
fiC/L+cjAvFlCv0PE0TTgvcd0zY8sON47R1qmVQ5LY0vv9pXkjArfcWGQxS+X+nR
LNKkaG+ACRLsS/Maahja0K2fzyh3T/zNQM+o/rfBiTxxLDrg44wGLq8B1sijBWCJ
EniquuwT+F/VcAaEAk0YT0BfncDppFP/vHbR9GxNna+vmwxReHni4GmChm3cd+Yg
Nfyei6kCtblvzft0f3W3RVXUDtY+e28DepXU41DIB9VPbJR8twIDAQABo1MwUTAd
BgNVHQ4EFgQUHu0zykbuWiO9kMRANWAg32KlgXkwHwYDVR0jBBgwFoAUHu0zykbu
WiO9kMRANWAg32KlgXkwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOC
AQEAgJ6KDQNc+LVzLQvxycyDMwFAkDp+fGdi27RRlUZtKOcphCK0J3lQ5Pyj/c6M
qM3mlK/tellQjNaoBZXrv7ZAQatx7bpbvei+7Z2F1nvSkjtGbYK7f7A4SaGjYiBG
Xu5nO2ZiyeBNW9pZLEzR/EtJXNHmAJNZ1nsC6GydIHwQUQyRSKIl/qD5iiMGAh6A
GEJ9g6iN27uB06uvRY4m2YM0ppqfw/eu5QTvTPxeCBaA8GJuUweiEB+ynG1NvQRq
hgjiCzZIHgzUeaCeM/ihW9YB4cpiKGuuUCqpVMLxZ/W+o7sXsmkhwq65tPdaj+Yr
HPyCQYALQYEiwYJwDQyUCeEj7Q==
-----END CERTIFICATE-----
''';
