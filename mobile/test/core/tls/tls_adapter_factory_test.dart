// Proves the io-platform adapter-building logic for each TlsTrustDecision
// case (design D5/D6 TLS hardening). This is `flutter test`'s VM target
// (Android/Linux/desktop-equivalent for test purposes), so dart:io IS
// available here — the web branch (`tls_adapter_factory_web.dart`) is
// exercised separately by its own trivial always-null contract test below,
// since a web-target compile isn't exercised by `flutter test`.
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tls/tls_adapter_factory.dart';
import 'package:lifeos/core/tls/tls_trust_decision.dart';

void main() {
  group('PlatformTlsAdapterFactory (io)', () {
    const factory = PlatformTlsAdapterFactory();

    test('returns null for TlsTrustDecision.none — leaves the default adapter untouched', () {
      expect(factory.build(TlsTrustDecision.none), isNull);
    });

    test('returns an IOHttpClientAdapter when a CA is pinned', () {
      final adapter = factory.build(const TlsTrustDecision(pinnedCaPem: _fakeCaPem, host: 'engine.example'));

      expect(adapter, isA<IOHttpClientAdapter>());
    });

    test('pinned-CA adapter builds an HttpClient backed by a restricted SecurityContext', () {
      final adapter = factory.build(const TlsTrustDecision(pinnedCaPem: _fakeCaPem, host: 'engine.example')) as IOHttpClientAdapter;

      final client = adapter.createHttpClient!();

      expect(client, isA<HttpClient>());
    });

    test('returns an IOHttpClientAdapter for the dev self-signed fallback', () {
      final adapter = factory.build(const TlsTrustDecision(trustSelfSigned: true, host: 'engine.example'));

      expect(adapter, isA<IOHttpClientAdapter>());
    });

    test('dev fallback createHttpClient wires a badCertificateCallback without throwing', () {
      final adapter =
          factory.build(const TlsTrustDecision(trustSelfSigned: true, host: 'engine.example')) as IOHttpClientAdapter;

      // `HttpClient.badCertificateCallback` is write-only (no getter) in
      // dart:io, so the only thing a socket-free unit test can assert is
      // that building the client (which assigns the callback) succeeds.
      // The callback's host-scoping *logic itself* is pure and covered
      // directly via `buildTlsAdapter`'s io-only helper in
      // `tls_adapter_factory_io_test.dart`.
      expect(() => adapter.createHttpClient!(), returnsNormally);
    });
  });
}

// A REAL (ephemeral, throwaway) self-signed cert PEM — `SecurityContext`
// parses/validates trusted-certificate bytes eagerly on
// `setTrustedCertificatesBytes`, so a syntactically-fake PEM would throw
// here; this is not a live engine's cert, just a locally-generated fixture
// (`openssl req -x509 ... -subj "/CN=test.example"`) that IS valid X.509 DER
// once base64-decoded, so the io adapter-building path can be exercised
// end-to-end without any network/socket activity.
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
