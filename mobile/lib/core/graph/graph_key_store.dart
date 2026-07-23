import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages the at-rest encryption key for the on-device graph database
/// (roadmap SLICE A2). Mirrors `axi/src/axi/store.py`'s `load_key()`: on the
/// first run it mints 32 random bytes and persists them hex-encoded; every
/// later run just reads them back. The key never leaves the device — here it
/// lives in the OS keystore (Android Keystore / iOS Keychain) via
/// [FlutterSecureStorage], not a world-readable file.
///
/// The hex string is handed straight to SQLCipher as a raw key
/// (`PRAGMA key = "x'<hex>'"`), so SQLCipher skips key derivation and uses
/// the 32 bytes as the AES-256 key directly — same scheme as store.py.
class GraphKeyStore {
  GraphKeyStore({FlutterSecureStorage? storage, Random? random})
      : _storage = storage ?? const FlutterSecureStorage(),
        _random = random ?? Random.secure();

  final FlutterSecureStorage _storage;
  final Random _random;

  /// Secure-storage key. Distinct from the pairing/token keys so it can be
  /// read/cleared independently (same convention as `core/auth/token_store`).
  static const String _secureKey = 'lifeos.graph.db_key';

  /// Return the persisted key, generating + storing one on first access.
  Future<String> loadOrCreateKey() async {
    final existing = await _storage.read(key: _secureKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final key = _generateKeyHex();
    await _storage.write(key: _secureKey, value: key);
    return key;
  }

  /// 32 cryptographically-random bytes, hex-encoded (64 chars) — a 256-bit key.
  String _generateKeyHex() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return _hex(bytes);
  }

  static String _hex(List<int> bytes) {
    const digits = '0123456789abcdef';
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer
        ..write(digits[(b >> 4) & 0xf])
        ..write(digits[b & 0xf]);
    }
    return buffer.toString();
  }
}

/// Base64 helper kept for parity/debugging; unused by the SQLCipher path but
/// handy if a future slice needs a non-hex encoding.
String base64OfHex(String hex) => base64Encode(
      List<int>.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
