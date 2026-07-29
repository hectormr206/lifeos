// TIMEOUT, calibrated not padded. These cases perform real AES-GCM sealing
// against a real temp directory. That takes ~3 s on an idle machine, but this
// suite also runs on a box shared with model inference and other projects'
// builds, where it has repeatedly exceeded the framework's generic 30 s
// default and failed CI with timeouts that reproduce nowhere else. A genuine
// hang still fails here — just later; every assertion is unchanged.
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
