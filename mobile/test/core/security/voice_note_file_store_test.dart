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
import 'package:lifeos/core/security/voice_note_directory.dart';
import 'package:lifeos/core/security/voice_note_file_store.dart';

void main() {
  // The durable notes directory is injectable: tests point it at a temp
  // `support` dir, mirroring the production
  // `<applicationSupportDirectory>/voice_notes/` layout.
  late Directory root;
  late Directory supportDir;
  late VoiceNoteFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lifeos-voice-security-');
    addTearDown(() => root.delete(recursive: true));
    supportDir = Directory('${root.path}/support')..createSync();
    store = VoiceNoteFileStore(
      cipher: _testCipher(),
      durableDirectory: VoiceNoteDirectory(
        directoryProvider: () async => supportDir,
      ),
      // Working copies use `root` as the OS temp dir, so the scratch dir is
      // `<root>/voice_notes_scratch/` — injectable, like production.
      scratchDirectoryProvider: () async => root,
    );
  });

  const bytes = [82, 73, 70, 70, 1, 2, 3, 4]; // RIFF + tiny fixture payload

  test(
    'sealRecording seals INTO the durable directory, never beside the temp recording',
    () async {
      final wav = File('${root.path}/voice-1000.wav')..writeAsBytesSync(bytes);

      final sealedPath = await store.sealRecording(wav.path);

      // LOCATION: the sealed blob is in <appSupport>/voice_notes/, not in the
      // recording's temp directory.
      expect(sealedPath, '${supportDir.path}/voice_notes/voice-1000.wav.lifeos');
      final sealed = File(sealedPath);
      expect(await sealed.exists(), isTrue);
      // The plaintext recording is gone, and its bytes are not in the blob.
      expect(await wav.exists(), isFalse);
      expect(
        _containsBytes(await sealed.readAsBytes(), bytes),
        isFalse,
        reason: 'the sealed blob must be ciphertext',
      );
    },
  );

  test(
    'withWav working copies live in the temp scratch dir, NEVER in durable storage',
    () async {
      final wav = File('${root.path}/voice-1000.wav')..writeAsBytesSync(bytes);
      final sealedPath = await store.sealRecording(wav.path);

      String? workingPath;
      await store.withWav(sealedPath, (temporaryPath) async {
        workingPath = temporaryPath;
        expect(await File(temporaryPath).readAsBytes(), bytes);
        // LOCATION: the scratch subdirectory of the injected temp dir…
        expect(workingPath, startsWith('${root.path}/voice_notes_scratch/'));
        // …never anywhere under the durable app-support directory.
        expect(workingPath!.startsWith(supportDir.path), isFalse);
      });
      // Guaranteed deletion after use.
      expect(await File(workingPath!).exists(), isFalse);

      // The durable directory holds ONLY the sealed blob: scan every file
      // byte-for-byte so a plaintext leak could never hide here.
      for (final entry in await Directory(
        '${supportDir.path}/voice_notes',
      ).list().toList()) {
        expect(
          entry.path.endsWith('.lifeos') && entry is File,
          isTrue,
          reason: 'unexpected file in durable storage: ${entry.path}',
        );
        expect(
          _containsBytes(await (entry as File).readAsBytes(), bytes),
          isFalse,
          reason: 'plaintext audio leaked into durable storage: ${entry.path}',
        );
      }
    },
  );

  test(
    'decryptToTemporaryWav materializes in the temp scratch dir, not durable',
    () async {
      final wav = File('${root.path}/voice-1000.wav')..writeAsBytesSync(bytes);
      final sealedPath = await store.sealRecording(wav.path);

      final temporaryPath = await store.decryptToTemporaryWav(sealedPath);

      // LOCATION: the scratch subdirectory of the injected temp dir, never
      // the durable directory.
      expect(temporaryPath, startsWith('${root.path}/voice_notes_scratch/'));
      expect(temporaryPath.startsWith(supportDir.path), isFalse);
      expect(await File(temporaryPath).readAsBytes(), bytes);

      await store.deleteTemporaryWav(temporaryPath);
      expect(await File(temporaryPath).exists(), isFalse);
    },
  );

  test(
    'migrateLegacy moves the legacy note INTO the durable directory',
    () async {
      final legacy = File('${root.path}/legacy/voice-2000.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

      final migratedPath = await store.migrateLegacy(legacy.path);

      // LOCATION: the sealed copy is durable; the source stays put until the
      // graph has committed to the new path (deleteLegacy happens after).
      expect(
        migratedPath,
        '${supportDir.path}/voice_notes/voice-2000.wav.lifeos',
      );
      final durablePath = migratedPath!;
      final sealed = File(durablePath);
      expect(await sealed.exists(), isTrue);
      expect(await legacy.exists(), isTrue);
      // The sealed copy decrypts back to the original bytes.
      await store.withWav(durablePath, (temporaryPath) async {
        expect(await File(temporaryPath).readAsBytes(), bytes);
      });
    },
  );

  test(
    'migrateLegacy surfaces a MISSING legacy source instead of keeping it',
    () async {
      final gone = '${root.path}/nowhere/voice-3000.wav';

      // `null` = dangling reference: the caller decides, the store does not
      // pretend the note is intact.
      expect(await store.migrateLegacy(gone), isNull);
    },
  );

  test(
    'a failed migration keeps the original path and never destroys the file',
    () async {
      final legacy = File('${root.path}/legacy/voice-4000.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final unavailable = VoiceNoteDirectory(
        directoryProvider: () async =>
            throw const FileSystemException('durable storage unavailable'),
      );
      final failingStore = VoiceNoteFileStore(
        cipher: _testCipher(),
        durableDirectory: unavailable,
        scratchDirectoryProvider: () async => root,
      );

      final result = await failingStore.migrateLegacy(legacy.path);

      // The legacy path is still genuinely usable — nothing was lost.
      expect(result, legacy.path);
      expect(await legacy.exists(), isTrue);
    },
  );

  test('migrateLegacy passes already-encrypted paths through unchanged', () async {
    const encrypted = '/somewhere/voice-5000.wav.lifeos';
    expect(await store.migrateLegacy(encrypted), encrypted);
  });
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
