import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// AES-256-GCM envelope for sensitive files that cannot be stored in the
/// SQLCipher graph. The per-purpose key remains in the OS-backed secure store;
/// filenames and the envelope header intentionally contain no user data.
class EncryptedFileCipher {
  EncryptedFileCipher({
    Future<SecretKey> Function()? keyProvider,
    AesGcm? algorithm,
  }) : _keyProvider = keyProvider ?? SecureFileKeyStore().loadOrCreate,
       _algorithm = algorithm ?? AesGcm.with256bits();

  final Future<SecretKey> Function() _keyProvider;
  final AesGcm _algorithm;

  static const _header = <int>[0x4c, 0x4f, 0x53, 0x45, 0x01]; // LOSE + version
  static const _nonceLength = 12;
  static const _macLength = 16;

  bool isEncrypted(List<int> bytes) {
    if (bytes.length < _header.length) return false;
    for (var index = 0; index < _header.length; index++) {
      if (bytes[index] != _header[index]) return false;
    }
    return true;
  }

  Future<Uint8List> seal(List<int> plaintext) async {
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: await _keyProvider(),
    );
    return Uint8List.fromList([..._header, ...box.concatenation()]);
  }

  /// Returns plaintext for a valid encrypted envelope, the original input for
  /// a legacy plaintext file, or null for a corrupt/tampered envelope.
  Future<Uint8List?> openOrLegacy(List<int> bytes) async {
    if (!isEncrypted(bytes)) return Uint8List.fromList(bytes);
    try {
      final box = SecretBox.fromConcatenation(
        Uint8List.fromList(bytes.sublist(_header.length)),
        nonceLength: _nonceLength,
        macLength: _macLength,
      );
      return Uint8List.fromList(
        await _algorithm.decrypt(box, secretKey: await _keyProvider()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeSealed(File destination, List<int> plaintext) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(await seal(plaintext), flush: true);
    await temporary.rename(destination.path);
  }
}

/// Owns a distinct 256-bit key for auxiliary encrypted files. It never writes
/// key material to the filesystem; FlutterSecureStorage maps to Android
/// Keystore / iOS Keychain in production.
class SecureFileKeyStore {
  SecureFileKeyStore({FlutterSecureStorage? storage, Random? random})
    : _storage = storage ?? const FlutterSecureStorage(),
      _random = random ?? Random.secure();

  final FlutterSecureStorage _storage;
  final Random _random;
  static const _keyName = 'lifeos.auxiliary_files.aes256gcm_key';

  Future<SecretKey> loadOrCreate() async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null && existing.length == 64) {
      return SecretKey(_decodeHex(existing));
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    await _storage.write(key: _keyName, value: _encodeHex(bytes));
    return SecretKey(bytes);
  }

  Future<void> deleteKey() => _storage.delete(key: _keyName);

  static String _encodeHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _decodeHex(String value) => List<int>.generate(
    value.length ~/ 2,
    (index) => int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
  );
}
