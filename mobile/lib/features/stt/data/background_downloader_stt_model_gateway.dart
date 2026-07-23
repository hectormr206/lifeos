import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

import '../domain/stt_model.dart';
import '../domain/stt_model_gateway.dart';
import 'stt_model_source_config.dart';

/// Raised when the model download cannot be completed or verified.
class SttModelDownloadException implements Exception {
  SttModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [SttModelGateway] backed by `background_downloader` (already a dependency),
/// fetching the three Whisper model files into the app-support dir on first
/// use (roadmap slice B2).
///
/// `background_downloader` (not Dio) so the fetch of the ~80 MB model survives
/// backgrounding and posts a progress notification — the same choice the
/// app-update APK download makes. After each file lands, its size is checked
/// against the manifest floor; a too-small file (an error page, a truncated
/// download) is deleted and the whole download fails, so a bogus model can
/// never reach the recognizer.
class BackgroundDownloaderSttModelGateway implements SttModelGateway {
  BackgroundDownloaderSttModelGateway({
    this._config = const SttModelSourceConfig(),
    FileDownloader? downloader,
  }) : _downloader = downloader ?? FileDownloader();

  final SttModelSourceConfig _config;
  final FileDownloader _downloader;

  static const String _group = 'stt_model';
  static const String _directory = 'stt_model';

  DownloadTask _taskFor(SttModelFile file) => DownloadTask(
        url: _joinUrl(_config.baseUrl, file.name),
        filename: file.name,
        group: _group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _directory,
        updates: Updates.statusAndProgress,
      );

  @override
  Future<SttModelPaths?> installedModel() async {
    try {
      final paths = await _resolvePaths();
      for (final entry in [
        (paths.encoder, _config.encoder.minBytes),
        (paths.decoder, _config.decoder.minBytes),
        (paths.tokens, _config.tokens.minBytes),
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
  Future<SttModelPaths> download({void Function(double progress)? onProgress}) async {
    if (!_config.isConfigured) {
      throw SttModelDownloadException('Origen del modelo de voz no configurado.');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset the app-update + model downloads use to avoid a re-attach loop).
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
        throw SttModelDownloadException(
          'La descarga del modelo de voz no se completó (${result.status.name}).',
        );
      }
      await _verifySize(await task.filePath(), file);
    }

    if (onProgress != null) onProgress(1.0);
    return _resolvePaths();
  }

  /// Verify the file at [path] is at least [file.minBytes]. Deletes it and
  /// throws on failure so a truncated/bogus file can never be used.
  Future<void> _verifySize(String path, SttModelFile file) async {
    final onDisk = File(path);
    int length;
    try {
      length = await onDisk.length();
    } catch (_) {
      throw SttModelDownloadException('No se pudo leer "${file.name}" tras la descarga.');
    }
    if (length < file.minBytes) {
      try {
        await onDisk.delete();
      } catch (_) {/* best effort — the size failure is what matters */}
      throw SttModelDownloadException('La verificación de "${file.name}" falló; descarga descartada.');
    }
  }

  Future<SttModelPaths> _resolvePaths() async {
    final encoder = await _taskFor(_config.encoder).filePath();
    final decoder = await _taskFor(_config.decoder).filePath();
    final tokens = await _taskFor(_config.tokens).filePath();
    return SttModelPaths(encoder: encoder, decoder: decoder, tokens: tokens);
  }

  static String _joinUrl(String base, String name) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$name';
  }
}
