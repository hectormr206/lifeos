import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// SHA-256 hex digest of raw certificate DER bytes, matching the engine's
/// own `_ca_der_sha256` format exactly (`axi/src/axi/dashboard.py`):
/// lowercase hex, no separators, computed over the DER bytes (not the PEM
/// text). Pure function — no I/O, unit-testable without a live engine or
/// any dart:io socket.
String sha256HexOfDer(Uint8List der) => crypto.sha256.convert(der).toString();

/// True iff [der]'s SHA-256 digest equals [expectedHex] (case-insensitive,
/// surrounding whitespace tolerated). An empty/blank [expectedHex] NEVER
/// matches — there is no such thing as an "unpinned" match; a caller with no
/// pin to compare against must not call this at all (see
/// `ca_provisioning_repository.dart` / `connection_notifier.dart` for where
/// "no pin provided" is handled as its own explicit case, not as a match).
bool fingerprintMatches(Uint8List der, String expectedHex) {
  final expected = expectedHex.trim();
  if (expected.isEmpty) return false;
  return sha256HexOfDer(der).toLowerCase() == expected.toLowerCase();
}

/// Decodes a PEM certificate's base64 body into raw DER bytes — the exact
/// inverse of the engine's own PEM->DER step (`_ca_der_sha256`): strip the
/// `-----BEGIN/END CERTIFICATE-----` lines, base64-decode what remains.
/// Throws [FormatException] on a malformed body (surfaced by callers as a
/// `CaProvisioningException`, never silently treated as "no CA").
Uint8List derFromPem(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return base64.decode(body);
}
