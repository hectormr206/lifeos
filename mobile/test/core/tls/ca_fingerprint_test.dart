// Pure logic (design D5/D6 TLS hardening, connection-hardening batch): the
// SHA-256 fingerprint compare used to pin the engine's mkcert root CA. No
// sockets, no dart:io TLS — just bytes in, hex/bool out. Values below match
// the engine's own `_ca_der_sha256` format exactly (dashboard.py): lowercase
// hex, no separators, computed over the raw DER bytes (not the PEM text).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tls/ca_fingerprint.dart';

void main() {
  group('sha256HexOfDer', () {
    test('computes a 64-char lowercase hex sha256 digest of DER bytes', () {
      final der = Uint8List.fromList(utf8.encode('fake-der-bytes'));

      final hex = sha256HexOfDer(der);

      expect(hex, hasLength(64));
      expect(hex, equals(hex.toLowerCase()));
      expect(hex, equals(crypto.sha256.convert(der).toString()));
    });
  });

  group('fingerprintMatches', () {
    test('matches when the expected hex equals the DER digest, case-insensitively', () {
      final der = Uint8List.fromList(utf8.encode('cert-bytes'));
      final expected = sha256HexOfDer(der);

      expect(fingerprintMatches(der, expected), isTrue);
      expect(fingerprintMatches(der, expected.toUpperCase()), isTrue);
      expect(fingerprintMatches(der, '  $expected  '), isTrue);
    });

    test('rejects a mismatched fingerprint', () {
      final der = Uint8List.fromList(utf8.encode('cert-bytes'));

      expect(fingerprintMatches(der, '0' * 64), isFalse);
    });

    test('rejects an empty/blank expected fingerprint — never an implicit match', () {
      final der = Uint8List.fromList(utf8.encode('cert-bytes'));

      expect(fingerprintMatches(der, ''), isFalse);
      expect(fingerprintMatches(der, '   '), isFalse);
    });
  });

  group('derFromPem', () {
    test('strips BEGIN/END CERTIFICATE lines and base64-decodes the body', () {
      final der = Uint8List.fromList(List.generate(32, (i) => i));
      final b64 = base64.encode(der);
      final pem = '-----BEGIN CERTIFICATE-----\n$b64\n-----END CERTIFICATE-----\n';

      expect(derFromPem(pem), equals(der));
    });

    test('tolerates CRLF line endings and surrounding whitespace', () {
      final der = Uint8List.fromList(List.generate(16, (i) => i * 2));
      final b64 = base64.encode(der);
      final pem = '-----BEGIN CERTIFICATE-----\r\n$b64\r\n-----END CERTIFICATE-----\r\n';

      expect(derFromPem(pem), equals(der));
    });

    test('throws FormatException on a non-base64 body', () {
      const pem = '-----BEGIN CERTIFICATE-----\nnot-valid-base64!!!\n-----END CERTIFICATE-----\n';

      expect(() => derFromPem(pem), throwsFormatException);
    });
  });
}
