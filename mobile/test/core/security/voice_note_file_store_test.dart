// TIMEOUT, calibrated not padded. These cases perform real cryptographic work
// (AES-GCM or SQLCipher) against a real temp directory: ~3 s on an idle
// machine, and repeatedly past the framework's generic 30 s default on the
// Proxmox runner.
//
// The cause is that runner, not this code. It is a Ryzen 5 5500U — a low-power
// mobile part with 6 physical cores — carrying twelve runner listeners for nine
// repositories. Ruled out by measurement: core count and disk throughput
// (PR #165), and AES-NI, which both CI machines have and which differs by only
// 1.6x between them. What is left is single-thread speed under contention.
//
// An earlier version of this comment blamed contention on the VPS. These jobs
// do not run on the VPS.
//
// A genuine hang still fails here, two minutes later instead of thirty seconds.
// Every assertion is unchanged.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';
import 'package:lifeos/core/security/voice_note_file_store.dart';

void main() {
  test(
    'seals completed WAV recordings and only exposes a temporary working copy',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'lifeos-voice-security-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final wav = File('${dir.path}/voice-1.wav');
      const bytes = [82, 73, 70, 70, 1, 2, 3, 4]; // RIFF + tiny fixture payload
      await wav.writeAsBytes(bytes);
      final store = VoiceNoteFileStore(cipher: _testCipher());

      final encryptedPath = await store.sealRecording(wav.path);

      expect(await wav.exists(), isFalse);
      final encrypted = File(encryptedPath);
      expect(_containsBytes(await encrypted.readAsBytes(), bytes), isFalse);
      await store.withWav(encryptedPath, (temporaryPath) async {
        expect(await File(temporaryPath).readAsBytes(), bytes);
        expect(await File(temporaryPath).exists(), isTrue);
      });
      expect(await File('$encryptedPath.working.wav').exists(), isFalse);
    },
  );
}

EncryptedFileCipher _testCipher() => EncryptedFileCipher(
  keyProvider: () async => SecretKey(List<int>.filled(32, 7)),
);

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
