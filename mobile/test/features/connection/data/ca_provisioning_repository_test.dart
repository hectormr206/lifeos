// Proves fetching+parsing the engine's mkcert root CA (design D6:
// `GET {engineUrl}/axi-rootCA.crt`, dashboard.py:1188) — the CA used to pin
// the self-signed connection (connection-hardening batch). No live engine —
// a fixed HttpClientAdapter stands in for the socket, same pattern as
// `pairing_repository_test.dart`.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tls/ca_fingerprint.dart';
import 'package:lifeos/features/connection/data/ca_provisioning_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/x-x509-ca-cert'],
      },
    );
  }
}

const _validPem = '''
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

void main() {
  group('HttpCaProvisioningRepository', () {
    test('fetchRootCa() GETs /axi-rootCA.crt and parses PEM into der + fingerprint', () async {
      final adapter = _FixedResponseAdapter(statusCode: 200, body: _validPem);
      final repository = HttpCaProvisioningRepository(
        dioFactory: (engineUrl) => Dio(BaseOptions(baseUrl: engineUrl))..httpClientAdapter = adapter,
      );

      final ca = await repository.fetchRootCa('https://10.66.66.2:8081');

      expect(adapter.lastRequest?.path, '/axi-rootCA.crt');
      expect(adapter.lastRequest?.method, 'GET');
      expect(ca.pem, _validPem);
      expect(ca.der, equals(derFromPem(_validPem)));
      expect(ca.fingerprint, equals(sha256HexOfDer(derFromPem(_validPem))));
    });

    test('fetchRootCa() 404 (mkcert not installed) throws CaProvisioningException', () async {
      final adapter = _FixedResponseAdapter(statusCode: 404, body: '{"detail":"rootCA.pem not found"}');
      final repository = HttpCaProvisioningRepository(
        dioFactory: (engineUrl) => Dio(BaseOptions(baseUrl: engineUrl))..httpClientAdapter = adapter,
      );

      await expectLater(
        () => repository.fetchRootCa('https://10.66.66.2:8081'),
        throwsA(isA<CaProvisioningException>()),
      );
    });

    test('fetchRootCa() malformed (non-PEM) body throws CaProvisioningException', () async {
      final adapter = _FixedResponseAdapter(statusCode: 200, body: 'not a certificate at all');
      final repository = HttpCaProvisioningRepository(
        dioFactory: (engineUrl) => Dio(BaseOptions(baseUrl: engineUrl))..httpClientAdapter = adapter,
      );

      await expectLater(
        () => repository.fetchRootCa('https://10.66.66.2:8081'),
        throwsA(isA<CaProvisioningException>()),
      );
    });
  });
}
