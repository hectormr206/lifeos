// Pure logic for the dev self-signed-fallback certificate callback (design
// D5/D6 hardening): no socket, no X509Certificate, no HttpClient — just the
// host-scoping decision itself. `HttpClient.badCertificateCallback` has no
// getter in dart:io, so this extracted pure function is what makes the
// actual accept/reject rule unit-testable at all (see
// `tls_adapter_factory_test.dart` for the adapter-construction-level
// coverage that this logic is wired in correctly).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tls/tls_adapter_factory_io.dart';

void main() {
  group('shouldAcceptSelfSigned', () {
    test('accepts when the presented host matches the expected (paired) host', () {
      expect(shouldAcceptSelfSigned(expectedHost: '10.66.66.2', presentedHost: '10.66.66.2'), isTrue);
    });

    test('rejects a different presented host — never a global blind-accept', () {
      expect(shouldAcceptSelfSigned(expectedHost: '10.66.66.2', presentedHost: 'evil.example'), isFalse);
    });

    test('rejects when no expected host was ever scoped (fail closed, not open)', () {
      expect(shouldAcceptSelfSigned(expectedHost: null, presentedHost: '10.66.66.2'), isFalse);
    });
  });
}
