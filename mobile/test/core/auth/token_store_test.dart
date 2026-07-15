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
}
