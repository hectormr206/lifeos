// Proves the passphrase-sealed backup envelope: the SAME archive re-encrypted
// under a key derived from a user passphrase, so it can rest anywhere — the
// VPS, a USB stick, a cloud drive — and still only open for whoever knows the
// phrase. The device Keystore key protects the live database; it dies with the
// device, which is exactly why a recovery copy must not depend on it.
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/security/passphrase_backup_sealer.dart';

/// Deliberately cheap KDF parameters: these tests assert behavior, not cost.
/// The shipped defaults live in [PassphraseBackupSealer.defaultKdf].
const _fastKdf = BackupKdfParameters(
  memoryKiB: 1024,
  iterations: 1,
  parallelism: 1,
);

final _invalidKdfs = <BackupKdfParameters>[
  for (final memory in [-1, 0, 7, 65537, 0xffffffff, 0x100000000])
    BackupKdfParameters(memoryKiB: memory, iterations: 1, parallelism: 1),
  for (final iterations in [-1, 0, 4, 0xffffffff, 0x100000000])
    BackupKdfParameters(memoryKiB: 8, iterations: iterations, parallelism: 1),
  for (final parallelism in [-1, 0, 2, 255, 256])
    BackupKdfParameters(memoryKiB: 16, iterations: 1, parallelism: parallelism),
];

Uint8List _archive([int size = 4096]) =>
    Uint8List.fromList(List<int>.generate(size, (i) => (i * 31 + 7) % 256));

void main() {
  late PassphraseBackupSealer sealer;

  setUp(() {
    sealer = PassphraseBackupSealer(kdf: _fastKdf);
  });

  group('v1 KDF policy', () {
    test('accepts defaults, fast costs and inclusive boundaries', () {
      for (final kdf in [
        PassphraseBackupSealer.defaultKdf,
        _fastKdf,
        const BackupKdfParameters(memoryKiB: 8, iterations: 1, parallelism: 1),
        const BackupKdfParameters(
          memoryKiB: 65536,
          iterations: 3,
          parallelism: 1,
        ),
      ]) {
        expect(kdf.isValidForV1, isTrue);
      }
    });

    test('rejects out-of-policy costs without deriving a key', () {
      for (final kdf in _invalidKdfs) {
        expect(kdf.isValidForV1, isFalse);
      }
    });

    test('seal rejects invalid costs before requesting randomness', () async {
      for (final kdf in _invalidKdfs) {
        final random = _RandomProbe();
        final invalid = PassphraseBackupSealer(kdf: kdf, random: random);
        await expectLater(
          invalid.seal(_archive(1), passphrase: 'x'),
          throwsArgumentError,
        );
        expect(random.requested, isFalse);
      }
    });

    test('open rejects forged costs before reading salt for the KDF', () async {
      for (final kdf in _invalidKdfs.where(
        (kdf) =>
            kdf.memoryKiB >= 0 &&
            kdf.memoryKiB <= 0xffffffff &&
            kdf.iterations >= 0 &&
            kdf.iterations <= 0xffffffff &&
            kdf.parallelism >= 0 &&
            kdf.parallelism <= 255,
      )) {
        final header = _HeaderProbe(kdf);
        expect(await sealer.open(header, passphrase: 'x'), isNull);
        expect(header.saltRead, isFalse);
      }
    });

    test(
      'valid minimum header reaches salt and minimum cost round-trips',
      () async {
        const minimum = BackupKdfParameters(
          memoryKiB: 8,
          iterations: 1,
          parallelism: 1,
        );
        final header = _HeaderProbe(minimum);
        expect(await sealer.open(header, passphrase: 'x'), isNull);
        expect(header.saltRead, isTrue);
        final minimal = PassphraseBackupSealer(kdf: minimum);
        final sealed = await minimal.seal(_archive(1), passphrase: 'x');
        expect(await sealer.open(sealed, passphrase: 'x'), _archive(1));
      },
    );
  });

  group('round-trip', () {
    test('opens with the passphrase it was sealed under', () async {
      final plain = _archive();

      final sealed = await sealer.seal(plain, passphrase: 'correcta caballo');
      final opened = await sealer.open(sealed, passphrase: 'correcta caballo');

      expect(opened, plain);
    });

    test('survives an empty archive', () async {
      final sealed = await sealer.seal(Uint8List(0), passphrase: 'x');
      expect(await sealer.open(sealed, passphrase: 'x'), isEmpty);
    });

    test('a unicode passphrase round-trips', () async {
      final plain = _archive(256);
      final sealed = await sealer.seal(
        plain,
        passphrase: 'contraseñá ñandú 🔐',
      );
      expect(
        await sealer.open(sealed, passphrase: 'contraseñá ñandú 🔐'),
        plain,
      );
    });
  });

  group('refusal', () {
    test('the wrong passphrase yields null, never plaintext', () async {
      final sealed = await sealer.seal(_archive(), passphrase: 'la buena');

      expect(await sealer.open(sealed, passphrase: 'la mala'), isNull);
    });

    test('tampering with the ciphertext is detected', () async {
      final sealed = await sealer.seal(_archive(), passphrase: 'frase');
      // Flip a bit well past the header, inside the ciphertext body.
      sealed[sealed.length - 40] ^= 0x01;

      expect(await sealer.open(sealed, passphrase: 'frase'), isNull);
    });

    test('tampering with the stored KDF cost is detected', () async {
      final sealed = await sealer.seal(_archive(), passphrase: 'frase');
      // The cost lives in the header. An attacker lowering it to make an
      // offline guess cheap must not produce a readable archive.
      final header = PassphraseBackupSealer.headerLength;
      sealed[header - 30] ^= 0x08;

      expect(await sealer.open(sealed, passphrase: 'frase'), isNull);
    });

    test('foreign bytes are rejected rather than misread', () async {
      expect(
        await sealer.open(Uint8List.fromList([1, 2, 3, 4]), passphrase: 'x'),
        isNull,
      );
    });
  });

  group('envelope', () {
    test('never contains the plaintext', () async {
      final plain = Uint8List.fromList('llamar al doctor el martes'.codeUnits);

      final sealed = await sealer.seal(plain, passphrase: 'frase');

      expect(_contains(sealed, plain), isFalse);
    });

    test(
      'sealing twice yields different bytes (fresh salt and nonce)',
      () async {
        final plain = _archive(128);

        final a = await sealer.seal(plain, passphrase: 'misma frase');
        final b = await sealer.seal(plain, passphrase: 'misma frase');

        expect(a, isNot(b));
        // Both still open — the difference is randomness, not corruption.
        expect(await sealer.open(a, passphrase: 'misma frase'), plain);
        expect(await sealer.open(b, passphrase: 'misma frase'), plain);
      },
    );

    test('carries its own KDF cost so old backups keep opening', () async {
      // Sealed cheaply, then read by a sealer configured expensively: the
      // envelope's parameters must win, otherwise raising the shipped cost
      // would strand every archive made before the change.
      final plain = _archive(64);
      final sealed = await sealer.seal(plain, passphrase: 'frase');

      final stricter = PassphraseBackupSealer(
        kdf: const BackupKdfParameters(
          memoryKiB: 4096,
          iterations: 3,
          parallelism: 1,
        ),
      );

      expect(await stricter.open(sealed, passphrase: 'frase'), plain);
    });

    test('is recognisable without attempting decryption', () async {
      final sealed = await sealer.seal(_archive(32), passphrase: 'frase');

      expect(PassphraseBackupSealer.isSealed(sealed), isTrue);
      expect(PassphraseBackupSealer.isSealed(_archive(32)), isFalse);
      expect(PassphraseBackupSealer.isSealed(Uint8List(0)), isFalse);
    });
  });

  group('shipped defaults', () {
    test('cost is at least the OWASP floor for Argon2id', () {
      const kdf = PassphraseBackupSealer.defaultKdf;

      // OWASP: m=19 MiB, t=2, p=1 is the minimum acceptable configuration.
      expect(kdf.memoryKiB, greaterThanOrEqualTo(19456));
      expect(kdf.iterations, greaterThanOrEqualTo(2));
      expect(kdf.parallelism, greaterThanOrEqualTo(1));
    });

    test('an empty passphrase is refused outright', () async {
      expect(
        () => sealer.seal(_archive(), passphrase: ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

// Observes the boundary before salt extraction, which precedes key derivation.
// A null result alone could otherwise just be a late MAC failure.
class _HeaderProbe extends ListBase<int> {
  _HeaderProbe(BackupKdfParameters kdf) {
    _bytes.setRange(0, 8, 'LOSBKUP1'.codeUnits);
    final view = ByteData.sublistView(_bytes);
    view.setUint32(8, kdf.memoryKiB);
    view.setUint32(12, kdf.iterations);
    view.setUint8(16, kdf.parallelism);
  }

  final _bytes = Uint8List(PassphraseBackupSealer.headerLength);
  bool saltRead = false;

  @override
  int get length => _bytes.length;
  @override
  set length(int value) => throw UnsupportedError('fixed header');
  @override
  int operator [](int index) => _bytes[index];
  @override
  void operator []=(int index, int value) => _bytes[index] = value;

  @override
  List<int> sublist(int start, [int? end]) {
    if (start == 0 && end == length) return this;
    if (start == length - 16) {
      saltRead = true;
      // Keep guard regressions bounded: never run Argon2 on forged costs.
      throw StateError('salt extraction reached');
    }
    return _bytes.sublist(start, end);
  }
}

class _RandomProbe implements Random {
  bool requested = false;

  @override
  int nextInt(int max) {
    requested = true;
    throw StateError('randomness must not be requested');
  }

  @override
  bool nextBool() => throw StateError('unexpected randomness');
  @override
  double nextDouble() => throw StateError('unexpected randomness');
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
