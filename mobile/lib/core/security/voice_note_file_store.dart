import 'dart:io';

import 'encrypted_file_cipher.dart';

/// Stores completed voice recordings as authenticated encrypted blobs. A WAV
/// exists only while the recorder is active or while a native consumer needs a
/// short-lived working copy; persisted chat paths point to `.lifeos` files.
class VoiceNoteFileStore {
  VoiceNoteFileStore({EncryptedFileCipher? cipher})
    : _cipher = cipher ?? EncryptedFileCipher();

  final EncryptedFileCipher _cipher;
  static const encryptedExtension = '.lifeos';

  bool isEncryptedPath(String path) => path.endsWith(encryptedExtension);

  /// Seals a just-finalized WAV then removes the recorder's plaintext output.
  Future<String> sealRecording(String wavPath) async {
    final source = File(wavPath);
    if (!await source.exists()) return wavPath;
    final encrypted = File('$wavPath$encryptedExtension');
    await _cipher.writeSealed(encrypted, await source.readAsBytes());
    await source.delete();
    return encrypted.path;
  }

  /// Converts a legacy persisted WAV on first history load. If migration fails,
  /// the original path remains usable rather than making an old note vanish.
  Future<String> migrateLegacy(String path) async {
    if (isEncryptedPath(path)) return path;
    try {
      final source = File(path);
      if (!await source.exists()) return path;
      final encrypted = File('$path$encryptedExtension');
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
  /// Legacy paths pass through unchanged for backward compatibility.
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
    final temporary = File('${source.path}.working.wav');
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

  /// Materializes an encrypted note for a native player. The caller owns the
  /// returned temporary path and MUST delete it after playback completes.
  Future<String> decryptToTemporaryWav(String path) async {
    if (!isEncryptedPath(path)) {
      return path;
    }
    final source = File(path);
    final plaintext = await _cipher.openOrLegacy(await source.readAsBytes());
    if (plaintext == null) {
      throw const FileSystemException('Unable to decrypt voice note');
    }
    final temporary = File('${source.path}.working.wav');
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
