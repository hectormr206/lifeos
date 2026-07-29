import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Argon2id cost. Stored inside every envelope so raising the shipped defaults
/// never strands archives sealed under the old ones.
class BackupKdfParameters {
  const BackupKdfParameters({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  @override
  bool operator ==(Object other) =>
      other is BackupKdfParameters &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism);
}

/// Re-seals a graph backup under a key derived from a user passphrase.
///
/// WHY THIS EXISTS. The live database is encrypted with a SQLCipher key held in
/// the Android Keystore, and `VACUUM INTO` backups inherit that key. The
/// Keystore is never backed up, exported, or transferred, so a copy of such a
/// backup cannot be opened once the device is gone — precisely the case a
/// backup is for. Deriving a second key from something the user carries in
/// their head makes the archive independent of any single device.
///
/// It also makes the DESTINATION untrusted by design: the sealed file can rest
/// on the VPS, a USB stick, or a third-party drive without any of them being
/// able to read it. Storage choice becomes a convenience decision instead of a
/// security one.
///
/// FORMAT (all integers big-endian):
///
///     magic          8 bytes   "LOSBKUP1"
///     memoryKiB      4 bytes
///     iterations     4 bytes
///     parallelism    1 byte
///     salt          16 bytes
///     ---- header ends: 33 bytes, authenticated as AAD ----
///     nonce         12 bytes
///     ciphertext    n bytes    AES-256-GCM
///     mac           16 bytes
///
/// The header is passed as additional authenticated data, so editing the
/// stored cost to make an offline guess cheap invalidates the MAC instead of
/// yielding a decryptable archive.
class PassphraseBackupSealer {
  PassphraseBackupSealer({
    this._kdf = defaultKdf,
    Random? random,
  }) : _random = random ?? Random.secure();

  final BackupKdfParameters _kdf;
  final Random _random;

  /// Measured at ~1.1 s on a server core in pure Dart, so roughly 3–4 s on a
  /// phone: costly for an attacker guessing offline, tolerable for an action
  /// a user performs rarely. Comfortably above the OWASP Argon2id floor of
  /// m=19 MiB, t=2, p=1. `cryptography_flutter` accelerates AES-GCM but not
  /// Argon2, so this runs unaccelerated on device.
  static const defaultKdf = BackupKdfParameters(
    memoryKiB: 65536,
    iterations: 3,
    parallelism: 1,
  );

  static const List<int> _magic = <int>[
    0x4c, 0x4f, 0x53, 0x42, 0x4b, 0x55, 0x50, 0x31, // LOSBKUP1
  ];
  static const int _saltLength = 16;
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  /// Bytes before the nonce: magic + cost + salt.
  static const int headerLength = 8 + 4 + 4 + 1 + _saltLength;

  /// True when [bytes] carry this envelope, without deriving anything. Lets a
  /// restore flow tell "needs a passphrase" from "plain archive" before asking
  /// the user for one.
  static bool isSealed(List<int> bytes) {
    if (bytes.length < headerLength) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  Future<Uint8List> seal(
    List<int> archive, {
    required String passphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError.value(
        passphrase,
        'passphrase',
        'refusing to seal a backup with an empty passphrase: the archive '
            'would be readable by anyone holding the file',
      );
    }

    final salt = Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => _random.nextInt(256)),
    );
    final header = _buildHeader(_kdf, salt);
    final key = await _deriveKey(passphrase, salt: salt, kdf: _kdf);

    final box = await AesGcm.with256bits().encrypt(
      archive,
      secretKey: key,
      aad: header,
    );

    return Uint8List.fromList([...header, ...box.concatenation()]);
  }

  /// Returns the archive, or null when the passphrase is wrong, the bytes were
  /// tampered with, or they are not a sealed envelope at all. Never throws for
  /// untrusted input and never returns partially-decrypted output.
  Future<Uint8List?> open(
    List<int> bytes, {
    required String passphrase,
  }) async {
    if (!isSealed(bytes) || passphrase.isEmpty) return null;
    try {
      final header = bytes.sublist(0, headerLength);
      final kdf = _readKdf(header);
      final salt = Uint8List.fromList(header.sublist(headerLength - _saltLength));

      final key = await _deriveKey(passphrase, salt: salt, kdf: kdf);
      final box = SecretBox.fromConcatenation(
        Uint8List.fromList(bytes.sublist(headerLength)),
        nonceLength: _nonceLength,
        macLength: _macLength,
      );

      return Uint8List.fromList(
        await AesGcm.with256bits().decrypt(box, secretKey: key, aad: header),
      );
    } catch (_) {
      // SecretBoxAuthenticationError for a wrong passphrase or tampering, and
      // RangeError/FormatException for a truncated file. All mean the same
      // thing to a caller: this archive did not open.
      return null;
    }
  }

  Future<SecretKey> _deriveKey(
    String passphrase, {
    required Uint8List salt,
    required BackupKdfParameters kdf,
  }) async {
    final argon2 = Argon2id(
      memory: kdf.memoryKiB,
      iterations: kdf.iterations,
      parallelism: kdf.parallelism,
      hashLength: 32,
    );
    return argon2.deriveKey(
      // utf8, not codeUnits: an accented or emoji passphrase must derive the
      // same key on every platform.
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static Uint8List _buildHeader(BackupKdfParameters kdf, Uint8List salt) {
    final header = Uint8List(headerLength);
    header.setRange(0, 8, _magic);
    final view = ByteData.sublistView(header);
    view.setUint32(8, kdf.memoryKiB);
    view.setUint32(12, kdf.iterations);
    view.setUint8(16, kdf.parallelism);
    header.setRange(headerLength - _saltLength, headerLength, salt);
    return header;
  }

  static BackupKdfParameters _readKdf(List<int> header) {
    final view = ByteData.sublistView(Uint8List.fromList(header));
    return BackupKdfParameters(
      memoryKiB: view.getUint32(8),
      iterations: view.getUint32(12),
      parallelism: view.getUint8(16),
    );
  }
}
