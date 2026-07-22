import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';

import '../../../core/auth/token_store.dart';
import '../domain/app_manifest.dart';

/// Raised when a downloaded APK fails verification and must be rejected.
class ApkDownloadException implements Exception {
  ApkDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the published APK from `GET /api/app/download` and verifies it
/// before it is ever handed to the installer (self-hosted OTA update).
///
/// The download goes through `background_downloader` (already a dependency)
/// rather than Dio so it survives backgrounding and posts a progress
/// notification — with the pairing Bearer token attached as an
/// `Authorization` header (the same header `AuthInterceptor` adds to Dio
/// requests). After the bytes land, the file's SHA-256 is checked against the
/// manifest; a mismatch deletes the file and throws, so a corrupt/tampered APK
/// can never reach the package installer.
class ApkDownloadService {
  ApkDownloadService(this._tokenStore, {FileDownloader? downloader})
      : _downloader = downloader ?? FileDownloader();

  final TokenStore _tokenStore;
  final FileDownloader _downloader;

  static const String _group = 'app_updates';
  static const String _filename = 'lifeos-update.apk';

  /// Download + verify the APK described by [manifest]. Emits progress in
  /// `0.0..1.0`; the final event is the absolute file path prefixed with
  /// `file:` once verification passes. Throws [ApkDownloadException] on a
  /// missing pairing, a failed download, or a sha256 mismatch.
  ///
  /// (Returns the verified path rather than a stream event to keep the caller
  /// simple; progress is delivered via [onProgress].)
  Future<String> downloadAndVerify(
    AppManifest manifest, {
    void Function(double progress)? onProgress,
  }) async {
    final stored = await _tokenStore.load();
    if (stored == null) {
      throw ApkDownloadException('No hay conexión emparejada para descargar.');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset the model download uses to avoid a re-attach loop).
    try {
      await _downloader.reset(group: _group);
    } catch (_) {/* opportunistic */}

    final url = _joinUrl(stored.engineUrl, '/api/app/download');
    final task = DownloadTask(
      url: url,
      headers: {'Authorization': 'Bearer ${stored.token}'},
      filename: _filename,
      group: _group,
      baseDirectory: BaseDirectory.temporary,
      directory: 'app_updates',
      updates: Updates.statusAndProgress,
    );

    final result = await _downloader.download(
      task,
      onProgress: (p) {
        if (p >= 0 && onProgress != null) onProgress(p);
      },
    );
    if (result.status != TaskStatus.complete) {
      throw ApkDownloadException('La descarga no se completó (${result.status.name}).');
    }

    final path = await task.filePath();
    await verifyApk(path, manifest.sha256);
    return path;
  }

  /// Verify the file at [path] has SHA-256 == [expectedSha256]. Deletes the
  /// file and throws [ApkDownloadException] on mismatch or a read failure.
  Future<void> verifyApk(String path, String expectedSha256) async {
    final file = File(path);
    final Digest digest;
    try {
      digest = sha256.convert(await file.readAsBytes());
    } catch (_) {
      throw ApkDownloadException('No se pudo leer el archivo descargado.');
    }
    final actual = digest.toString().toLowerCase();
    if (actual != expectedSha256.toLowerCase()) {
      try {
        await file.delete();
      } catch (_) {/* best effort — the mismatch is what matters */}
      throw ApkDownloadException('La verificación SHA-256 falló; descarga descartada.');
    }
  }

  static String _joinUrl(String base, String path) {
    if (base.endsWith('/')) return base.substring(0, base.length - 1) + path;
    return base + path;
  }
}
