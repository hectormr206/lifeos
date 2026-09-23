import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'encrypted_file_cipher.dart';
import 'voice_note_directory.dart';

/// Stores completed voice recordings as authenticated encrypted blobs in the
/// DURABLE voice-note directory ([VoiceNoteDirectory]). A WAV exists only
/// while the recorder is active or while a native consumer needs a short-lived
/// working copy; persisted chat paths point to `.lifeos` files.
///
/// Plaintext audio NEVER lives beside the sealed blob: working copies are
/// written to a dedicated scratch subdirectory of the OS temp dir. Once the
/// sealed blob became durable, writing a working copy beside it would put
/// PLAINTEXT audio into durable storage — a leak this layout makes
/// structurally impossible.
class VoiceNoteFileStore {
  VoiceNoteFileStore({
    EncryptedFileCipher? cipher,
    VoiceNoteDirectory? durableDirectory,
    Future<Directory> Function()? scratchDirectoryProvider,
  }) : _cipher = cipher ?? EncryptedFileCipher(),
       _durable = durableDirectory ?? VoiceNoteDirectory(),
       _scratchDirectoryProvider =
           scratchDirectoryProvider ?? getTemporaryDirectory;

  final EncryptedFileCipher _cipher;
  final VoiceNoteDirectory _durable;
  final Future<Directory> Function() _scratchDirectoryProvider;

  static const encryptedExtension = '.lifeos';

  /// Dedicated temp scratch area for short-lived plaintext working copies.
  /// Kept apart from the durable directory so even a crash mid-playback can
  /// never leave plaintext audio in durable storage.
  static const _scratchSubdir = 'voice_notes_scratch';

  bool isEncryptedPath(String path) => path.endsWith(encryptedExtension);

  /// The scratch subdirectory of the OS temp dir, created when missing.
  Future<Directory> _scratchDirectory() async {
    final base = await _scratchDirectoryProvider();
    final directory = Directory('${base.path}/$_scratchSubdir');
    await directory.create(recursive: true);
    return directory;
  }

  static String _fileName(String path) => path.split('/').last;

  /// Seals a just-finalized WAV INTO the durable directory, then removes the
  /// recorder's plaintext output from temp. The output location is derived
  /// from the durable directory — never from the input path — so the sealed
  /// blob and the plaintext recording never share a directory.
  Future<String> sealRecording(String wavPath) async {
    final source = File(wavPath);
    if (!await source.exists()) return wavPath;
    final durable = await _durable.resolve();
    final encrypted = File(
      '${durable.path}/${_fileName(wavPath)}$encryptedExtension',
    );
    await _cipher.writeSealed(encrypted, await source.readAsBytes());
    await source.delete();
    return encrypted.path;
  }

  /// Converts a legacy persisted WAV on first history load. The sealed copy
  /// lands in the durable directory; the legacy file stays put until the
  /// graph has committed to the new path, so a failed migration never
  /// destroys the old note.
  ///
  /// Returns the new durable path, the original [path] when sealing failed
  /// (the legacy file still exists and remains usable), or `null` when the
  /// legacy source is GONE — surfacing the dangling reference so the caller
  /// decides what that means, instead of the store pretending the note is
  /// intact.
  Future<String?> migrateLegacy(String path) async {
    if (isEncryptedPath(path)) return path;
    final source = File(path);
    if (!await source.exists()) return null;
    try {
      final durable = await _durable.resolve();
      final encrypted = File(
        '${durable.path}/${_fileName(path)}$encryptedExtension',
      );
      await _cipher.writeSealed(encrypted, await source.readAsBytes());
      // Keep the old file until its graph path has committed to the new value.
      return encrypted.path;
    } catch (_) {
      return path;
    }
  }

  Future<void> deleteLegacy(String path) async {
    try {
      final source = File(path);
      if (await source.exists()) await source.delete();
    } catch (_) {}
  }

  /// Gives STT/playback a temporary WAV and guarantees deletion afterwards.
  /// The working copy is written to the temp scratch dir — never beside the
  /// (now durable) blob. Legacy paths pass through unchanged for backward
  /// compatibility.
  Future<T> withWav<T>(
    String path,
    Future<T> Function(String wavPath) action,
  ) async {
    if (!isEncryptedPath(path)) {
      return action(path);
    }
    final source = File(path);
    final plaintext = await _cipher.openOrLegacy(await source.readAsBytes());
    if (plaintext == null) {
      throw const FileSystemException('Unable to decrypt voice note');
    }
    final scratch = await _scratchDirectory();
    final temporary = File(
      '${scratch.path}/${_fileName(source.path)}.working.wav',
    );
    await temporary.writeAsBytes(plaintext, flush: true);
    try {
      return await action(temporary.path);
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // The OS will reclaim a failed short-lived working copy.
      }
    }
  }

  /// Materializes an encrypted note for a native player, in the temp scratch
  /// dir — never in durable storage. The caller owns the returned path and
  /// MUST delete it after playback completes.
  Future<String> decryptToTemporaryWav(String path) async {
    if (!isEncryptedPath(path)) {
      return path;
    }
    final source = File(path);
    final plaintext = await _cipher.openOrLegacy(await source.readAsBytes());
    if (plaintext == null) {
      throw const FileSystemException('Unable to decrypt voice note');
    }
    final scratch = await _scratchDirectory();
    final temporary = File(
      '${scratch.path}/${_fileName(source.path)}.working.wav',
    );
    await temporary.writeAsBytes(plaintext, flush: true);
    return temporary.path;
  }

  Future<void> deleteTemporaryWav(String path) async {
    if (!path.endsWith('.working.wav')) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
