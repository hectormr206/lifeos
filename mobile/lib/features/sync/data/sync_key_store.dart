// Where the recovery entropy lives on this device.
//
// The 16 BYTES are stored, never the twelve words. They are cryptographically
// equivalent — the words are just a human-readable encoding of them — but a
// hex blob means nothing to a glance over a shoulder, a screenshot, or a
// support log that accidentally dumps storage. The words exist for paper; the
// bytes exist for the machine.
//
// Backed by the OS keystore (Android Keystore / iOS Keychain / libsecret) via
// FlutterSecureStorage, following the same pattern as `SecureFileKeyStore` in
// `core/security/encrypted_file_cipher.dart`.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SyncKeyStore {
  Future<List<int>?> readEntropy();
  Future<void> writeEntropy(List<int> entropy);
  Future<void> clear();
}

class SecureSyncKeyStore implements SyncKeyStore {
  SecureSyncKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'lifeos.sync.recovery_entropy';

  @override
  Future<List<int>?> readEntropy() async {
    final hex = await _storage.read(key: _key);
    // A stored value of the wrong length is corruption, not a short key: refuse
    // it rather than deriving something from a truncated read, which would
    // produce a key that opens nothing with no error to explain it.
    if (hex == null || hex.length != 32) return null;
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  @override
  Future<void> writeEntropy(List<int> entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('sync entropy is 16 bytes; got ${entropy.length}');
    }
    await _storage.write(
      key: _key,
      value: entropy.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
