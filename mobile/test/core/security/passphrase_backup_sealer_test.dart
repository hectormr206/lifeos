// Proves the passphrase-sealed backup envelope: the SAME archive re-encrypted
// under a key derived from a user passphrase, so it can rest anywhere — the
// VPS, a USB stick, a cloud drive — and still only open for whoever knows the
// phrase. The device Keystore key protects the live database; it dies with the
// device, which is exactly why a recovery copy must not depend on it.
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

Uint8List _archive([int size = 4096]) =>
    Uint8List.fromList(List<int>.generate(size, (i) => (i * 31 + 7) % 256));

void main() {
  late PassphraseBackupSealer sealer;

  setUp(() {
    sealer = PassphraseBackupSealer(kdf: _fastKdf);
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
      final sealed = await sealer.seal(plain, passphrase: 'contraseñá ñandú 🔐');
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

    test('sealing twice yields different bytes (fresh salt and nonce)',
        () async {
      final plain = _archive(128);

      final a = await sealer.seal(plain, passphrase: 'misma frase');
      final b = await sealer.seal(plain, passphrase: 'misma frase');

      expect(a, isNot(b));
      // Both still open — the difference is randomness, not corruption.
      expect(await sealer.open(a, passphrase: 'misma frase'), plain);
      expect(await sealer.open(b, passphrase: 'misma frase'), plain);
    });

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
