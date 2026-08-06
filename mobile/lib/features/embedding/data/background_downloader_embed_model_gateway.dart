import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

import '../domain/embed_model.dart';
import '../domain/embed_model_gateway.dart';
import 'embed_model_source_config.dart';
import '../../app_update/domain/update_source_config.dart';

/// Raised when the embedding-model download cannot be completed or verified.
class EmbedModelDownloadException implements Exception {
  EmbedModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [EmbedModelGateway] backed by `background_downloader` (already a
/// dependency), fetching the EmbeddingGemma model + tokenizer into the
/// app-support dir on first use (roadmap SLICE B1b).
///
/// `background_downloader` (not Dio) so the fetch of the ~179 MB model
/// survives backgrounding — the same choice the STT model and app-update
/// downloads make. After each file lands, its size is checked against the
/// manifest floor; a too-small file (an error page, a truncated download) is
/// deleted and the whole download fails, so a bogus model can never reach the
/// embedding runtime.
class BackgroundDownloaderEmbedModelGateway implements EmbedModelGateway {
  BackgroundDownloaderEmbedModelGateway({
    this._config = const EmbedModelSourceConfig(),
    FileDownloader? downloader,
  }) : _downloader = downloader ?? FileDownloader();

  final EmbedModelSourceConfig _config;
  final FileDownloader _downloader;

  static const String _group = 'embed_model';
  static const String _directory = 'embed_model';

  DownloadTask _taskFor(EmbedModelFile file) => DownloadTask(
        // The update source's access key, exactly as the APK download sends
        // it. Harmless today: /model/, /stt/, /tts/ and /embed/ are still
        // open. It is here so they CAN be closed — gating them while any
        // device still omitted the header would break model downloads on that
        // device, so the header has to ship and propagate first.
        headers: {kUpdateAccessKeyHeader: kUpdateAccessKey},
        url: _joinUrl(_config.baseUrl, file.name),
        filename: file.name,
        group: _group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _directory,
        // Automatic and heavy: Wi-Fi only, held by the OS until then.
        // See core/network/heavy_download_policy.dart.
        requiresWiFi: kHeavyDownloadsRequireWiFi,
      );

  @override
  Future<EmbedModelPaths?> installedModel() async {
    try {
      final paths = await _resolvePaths();
      for (final entry in [
        (paths.model, _config.model.minBytes),
        (paths.tokenizer, _config.tokenizer.minBytes),
      ]) {
        final file = File(entry.$1);
        if (!file.existsSync() || await file.length() < entry.$2) return null;
      }
      return paths;
    } catch (_) {
      // A probe failure (no support dir, IO error) reads as "not installed".
      return null;
    }
  }

  @override
  Future<EmbedModelPaths> download({void Function(double progress)? onProgress}) async {
    if (!_config.isConfigured) {
      throw EmbedModelDownloadException('Origen del modelo de memoria no configurado.');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset the app-update + STT model downloads use to avoid a re-attach loop).
    try {
      await _downloader.reset(group: _group);
    } catch (_) {/* opportunistic */}

    final files = _config.files;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final task = _taskFor(file);
      final result = await _downloader.download(
        task,
        onProgress: (p) {
          if (p < 0 || onProgress == null) return;
          // Weight each file equally across the aggregate 0..1 bar.
          onProgress((i + p) / files.length);
        },
      );
      if (result.status != TaskStatus.complete) {
        throw EmbedModelDownloadException(
          'La descarga del modelo de memoria no se completó (${result.status.name}).',
        );
      }
      await _verifySize(await task.filePath(), file);
    }

    if (onProgress != null) onProgress(1.0);
    return _resolvePaths();
  }

  /// Verify the file at [path] is at least [file.minBytes]. Deletes it and
  /// throws on failure so a truncated/bogus file can never be used.
  Future<void> _verifySize(String path, EmbedModelFile file) async {
    final onDisk = File(path);
    int length;
    try {
      length = await onDisk.length();
    } catch (_) {
      throw EmbedModelDownloadException('No se pudo leer "${file.name}" tras la descarga.');
    }
    if (length < file.minBytes) {
      try {
        await onDisk.delete();
      } catch (_) {/* best effort — the size failure is what matters */}
      throw EmbedModelDownloadException('La verificación de "${file.name}" falló; descarga descartada.');
    }
  }

  Future<EmbedModelPaths> _resolvePaths() async {
    final model = await _taskFor(_config.model).filePath();
    final tokenizer = await _taskFor(_config.tokenizer).filePath();
    return EmbedModelPaths(model: model, tokenizer: tokenizer);
  }

  static String _joinUrl(String base, String name) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$name';
  }
}
