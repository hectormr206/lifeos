import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/brain_model_manifest.dart';
import '../domain/brain_model_update_gateway.dart';
import 'brain_model_location.dart';
import 'brain_model_source_config.dart';
import '../../app_update/domain/update_source_config.dart';

/// [BrainModelUpdateGateway] backed by Dio (manifest) + `background_downloader`
/// (weights) — the same stack as the APK OTA (`AppUpdateService` +
/// `ApkDownloadService`), because the ~2.6GB fetch must survive backgrounding
/// and be resumable (`allowPause` + retries; background_downloader resumes a
/// partial fetch when the server supports ranges — nginx static files do).
///
/// Flow: download to `<app-support>/brain_model/gemma-4-E2B-it.litertlm.part`,
/// stream-hash it (SHA-256 — 2.6GB is far too big for readAsBytes), compare
/// against the manifest, then atomically rename over the STABLE final path.
/// Only that verified final path is ever handed to flutter_gemma's
/// `installModel().fromFile()` — a corrupt/truncated download can never reach
/// the inference runtime.
class VpsBrainModelGateway implements BrainModelUpdateGateway {
  VpsBrainModelGateway({
    this.config = const BrainModelSourceConfig(),
    Dio? dio,
    FileDownloader? downloader,
  })  : _dio = dio ?? Dio(BaseOptions(baseUrl: config.baseUrl)),
        _injectedDownloader = downloader;

  final BrainModelSourceConfig config;
  final Dio _dio;

  /// Lazily resolved so merely CONSTRUCTING the gateway (e.g. in a unit test
  /// that only exercises manifest fetch / verification) never touches the
  /// background_downloader plugin.
  final FileDownloader? _injectedDownloader;
  FileDownloader get _downloader => _injectedDownloader ?? FileDownloader();

  static const String _group = 'brain_model';
  /// Shared with the engine's re-activation lookup: both have to name the SAME
  /// directory or a restart cannot find the weights this gateway parked.
  static const String _directory = kBrainModelDirName;

  /// Temp name the in-flight download lands under; renamed to
  /// [kBrainModelFileName] only after the SHA-256 check passes, so the stable
  /// path NEVER holds unverified bytes (and an in-use old file is only
  /// replaced by a verified new one).
  static const String partFileName = '$kBrainModelFileName.part';

  @override
  bool get isConfigured => config.isConfigured;

  @override
  Future<BrainModelManifest?> fetchManifest() async {
    if (!config.isConfigured) return null;
    try {
      final response = await _dio.get<Map<String, Object?>>('/manifest.json');
      final data = response.data;
      if (data == null) return null;
      return BrainModelManifest.fromJson(data);
    } on DioException {
      // Offline / 404 (nothing published) / host down — fail-soft, no update
      // info right now. Never an error the user has to see on app open.
      return null;
    } on FormatException {
      // Malformed manifest — treat as "no update info" rather than crash.
      return null;
    }
  }

  /// Build the [DownloadTask] for [manifest]: `<base>/<filename>` (public, no
  /// key header — like /stt /tts /embed). Exposed for testing the URL/paths
  /// wiring without touching the network.
  @visibleForTesting
  DownloadTask buildDownloadTask(BrainModelManifest manifest) => DownloadTask(
        // The update source's access key, exactly as the APK download sends
        // it. Harmless today: /model/, /stt/, /tts/ and /embed/ are still
        // open. It is here so they CAN be closed — gating them while any
        // device still omitted the header would break model downloads on that
        // device, so the header has to ship and propagate first.
        headers: {kUpdateAccessKeyHeader: kUpdateAccessKey},
        url: _joinUrl(config.baseUrl, manifest.filename),
        filename: partFileName,
        group: _group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _directory,
        updates: Updates.statusAndProgress,
        // Automatic and heavy: Wi-Fi only, held by the OS until then.
        // See core/network/heavy_download_policy.dart.
        requiresWiFi: kHeavyDownloadsRequireWiFi,
        // Resume support for the 2.6GB fetch: pausable tasks resume from the
        // partial temp file instead of restarting, and transient network
        // failures are retried before surfacing an error.
        allowPause: true,
        retries: 5,
      );

  @override
  Future<String> downloadAndVerify(
    BrainModelManifest manifest, {
    void Function(double progress)? onProgress,
  }) async {
    if (!config.isConfigured) {
      throw BrainModelDownloadException('Origen del modelo no configurado.');
    }
    if (manifest.filename.isEmpty || manifest.sha256.isEmpty) {
      throw BrainModelDownloadException('El manifiesto del modelo está incompleto.');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset every house download uses to avoid the re-attach-to-failed loop).
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
      throw BrainModelDownloadException(
        'La descarga del modelo no se completó (${result.status.name}).',
      );
    }

    final partPath = await task.filePath();
    await verifyModelFile(partPath, manifest);

    // Verified — move onto the stable path (replacing any previous version;
    // a same-directory rename is atomic, and the old file's bytes stay valid
    // for an already-loaded model until it is disposed + re-installed).
    final finalPath =
        '${File(partPath).parent.path}${Platform.pathSeparator}$kBrainModelFileName';
    await File(partPath).rename(finalPath);
    if (onProgress != null) onProgress(1.0);
    return finalPath;
  }

  /// Verify the file at [path] against [manifest]: size floor (when the
  /// manifest declares one) + streamed SHA-256. Deletes the file and throws
  /// [BrainModelDownloadException] on any mismatch, so a truncated/tampered
  /// download can never be installed.
  @visibleForTesting
  Future<void> verifyModelFile(String path, BrainModelManifest manifest) async {
    final file = File(path);
    final int length;
    final Digest digest;
    try {
      length = await file.length();
      // Streamed hash — the weights are ~2.6GB, never readAsBytes().
      digest = await sha256.bind(file.openRead()).first;
    } catch (_) {
      throw BrainModelDownloadException('No se pudo leer el modelo descargado.');
    }
    final sizeOk = manifest.sizeBytes <= 0 || length == manifest.sizeBytes;
    final shaOk = digest.toString().toLowerCase() == manifest.sha256.toLowerCase();
    if (!sizeOk || !shaOk) {
      try {
        await file.delete();
      } catch (_) {/* best effort — the mismatch is what matters */}
      throw BrainModelDownloadException(
        'La verificación del modelo falló; descarga descartada.',
      );
    }
  }

  @override
  Future<void> deleteLocalFile() async {
    // Best-effort removal of both the final file and any leftover .part.
    for (final name in const [kBrainModelFileName, partFileName]) {
      try {
        final path = await DownloadTask(
          url: 'https://unused.invalid/x', // only the path resolution is used
          filename: name,
          baseDirectory: BaseDirectory.applicationSupport,
          directory: _directory,
        ).filePath();
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {/* nothing to delete / no support dir — fine */}
    }
  }

  static String _joinUrl(String base, String name) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$name';
  }
}
