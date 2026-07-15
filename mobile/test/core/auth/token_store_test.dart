// StoredConnection value-equality only — SecureTokenStore itself is not
// unit-tested here: flutter_secure_storage needs libsecret at runtime on
// Linux desktop, unavailable in this test environment. Everything that
// needs a TokenStore in other tests uses FakeTokenStore instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/auth/token_store.dart';

void main() {
  test('StoredConnection value-equality compares engineUrl/token/deviceId', () {
    const a = StoredConnection(engineUrl: 'https://e', token: 't', deviceId: 'd');
    const b = StoredConnection(engineUrl: 'https://e', token: 't', deviceId: 'd');
    const c = StoredConnection(engineUrl: 'https://other', token: 't', deviceId: 'd');

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });

  // Connection-hardening batch (design D5/D6): TLS pinning fields persisted
  // alongside url/token/deviceId, defaulting to "no pin, no dev fallback"
  // for backward compatibility with connections paired before this batch.
  test('StoredConnection defaults caFingerprint/caCertificatePem to null and trustSelfSigned to false', () {
    const conn = StoredConnection(engineUrl: 'https://e', token: 't', deviceId: 'd');

    expect(conn.caFingerprint, isNull);
    expect(conn.caCertificatePem, isNull);
    expect(conn.trustSelfSigned, isFalse);
  });

  test('StoredConnection value-equality also compares the TLS pinning fields', () {
    const a = StoredConnection(
      engineUrl: 'https://e',
      token: 't',
      deviceId: 'd',
      caFingerprint: 'abc123',
      caCertificatePem: '-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----',
    );
    const b = StoredConnection(
      engineUrl: 'https://e',
      token: 't',
      deviceId: 'd',
      caFingerprint: 'abc123',
      caCertificatePem: '-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----',
    );
    const c = StoredConnection(engineUrl: 'https://e', token: 't', deviceId: 'd', trustSelfSigned: true);

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });
}
