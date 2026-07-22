import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/app_manifest.dart';
import '../domain/update_source_config.dart';

/// Raised when a downloaded APK fails verification and must be rejected.
class ApkDownloadException implements Exception {
  ApkDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the published APK from the PUBLIC update source
/// (`GET <base>/download`) and verifies it before it is ever handed to the
/// installer (self-hosted OTA update, WITHOUT pairing).
///
/// The download goes through `background_downloader` (already a dependency)
/// rather than Dio so it survives backgrounding and posts a progress
/// notification. Formerly it attached the pairing Bearer token from the
/// [TokenStore]; it now attaches only the bundled access key as the
/// [kUpdateAccessKeyHeader] header, so no pairing is required. After the bytes
/// land, the file's SHA-256 is checked against the manifest; a mismatch
/// deletes the file and throws, so a corrupt/tampered APK can never reach the
/// package installer.
class ApkDownloadService {
  ApkDownloadService({
    this._config = const UpdateSourceConfig.fromEnvironment(),
    FileDownloader? downloader,
  }) : _downloader = downloader ?? FileDownloader();

  final UpdateSourceConfig _config;
  final FileDownloader _downloader;

  static const String _group = 'app_updates';
  static const String _filename = 'lifeos-update.apk';

  /// Build the [DownloadTask] for [manifest]: `<base>/download` with the
  /// access-key header. Exposed for testing the URL + header wiring without
  /// touching the network.
  @visibleForTesting
  DownloadTask buildDownloadTask(AppManifest manifest) => DownloadTask(
        url: _joinUrl(_config.baseUrl, '/download'),
        headers: {kUpdateAccessKeyHeader: _config.accessKey},
        filename: _filename,
        group: _group,
        baseDirectory: BaseDirectory.temporary,
        directory: 'app_updates',
        updates: Updates.statusAndProgress,
      );

  /// Download + verify the APK described by [manifest]. Emits progress in
  /// `0.0..1.0`; returns the verified absolute file path once verification
  /// passes. Throws [ApkDownloadException] on an unconfigured source, a failed
  /// download, or a sha256 mismatch.
  Future<String> downloadAndVerify(
    AppManifest manifest, {
    void Function(double progress)? onProgress,
  }) async {
    if (!_config.isConfigured) {
      throw ApkDownloadException('Origen de actualizaciones no configurado.');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset the model download uses to avoid a re-attach loop).
    try {
      await _downloader.reset(group: _group);
    } catch (_) {/* opportunistic */}

    final task = buildDownloadTask(manifest);

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
