import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

import '../domain/tts_voice.dart';
import '../domain/tts_voice_gateway.dart';
import 'piper_tokens.dart';
import 'tar_gz_extractor.dart';
import 'tts_voice_source_config.dart';

/// Raised when a voice download cannot be completed or verified.
class TtsVoiceDownloadException implements Exception {
  TtsVoiceDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [TtsVoiceGateway] backed by `background_downloader` (already a dependency),
/// fetching one Piper voice (model + config) per language plus the shared
/// espeak-ng-data archive into the app-support dir on first use (roadmap
/// slice B3) — the same pattern the STT model gateway established.
///
/// After the download it finishes the install locally:
///  * derives sherpa-onnx's `tokens.txt` from the voice's `*.onnx.json`
///    (`phoneme_id_map`), so the token table is never hosted;
///  * extracts `espeak-ng-data.tar.gz` once (shared by all voices) and deletes
///    the archive — `OfflineTtsVitsModelConfig.dataDir` needs the DIRECTORY.
///
/// Every downloaded file passes a size floor from the manifest; a too-small
/// file (error page, truncated download) is deleted and the download fails,
/// so a bogus voice can never reach the synthesizer.
class BackgroundDownloaderTtsVoiceGateway implements TtsVoiceGateway {
  BackgroundDownloaderTtsVoiceGateway({
    this._config = const TtsVoiceSourceConfig(),
    FileDownloader? downloader,
  }) : _downloader = downloader ?? FileDownloader();

  final TtsVoiceSourceConfig _config;
  final FileDownloader _downloader;

  static const String _group = 'tts_voice';
  static const String _directory = 'tts_model';

  /// A file that must exist inside an extracted espeak-ng-data dir — the
  /// cheap "was the archive really extracted" marker.
  static const String _espeakMarker = 'phontab';

  DownloadTask _taskFor(TtsVoiceFile file) => DownloadTask(
        url: _joinUrl(_config.baseUrl, file.name),
        filename: file.name,
        group: _group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _directory,
        updates: Updates.statusAndProgress,
      );

  @override
  Future<TtsVoicePaths?> installedVoice(String languageCode) async {
    final spec = _config.voiceForLanguage(languageCode);
    if (spec == null) return null;
    try {
      final paths = await _resolvePaths(spec);
      final model = File(paths.model);
      if (!model.existsSync() || await model.length() < spec.model.minBytes) return null;
      final tokens = File(paths.tokens);
      if (!tokens.existsSync() || await tokens.length() == 0) return null;
      if (!File('${paths.dataDir}/$_espeakMarker').existsSync()) return null;
      return paths;
    } catch (_) {
      // A probe failure (no support dir, IO error) reads as "not installed".
      return null;
    }
  }

  @override
  Future<TtsVoicePaths> download(
    String languageCode, {
    void Function(double progress)? onProgress,
  }) async {
    if (!_config.isConfigured) {
      throw TtsVoiceDownloadException('Origen de la voz neuronal no configurado.');
    }
    final spec = _config.voiceForLanguage(languageCode);
    if (spec == null) {
      throw TtsVoiceDownloadException('No hay voz neuronal para "$languageCode".');
    }

    // Clear any stale/failed task record for our group first (same defensive
    // reset the STT + app-update downloads use to avoid a re-attach loop).
    try {
      await _downloader.reset(group: _group);
    } catch (_) {/* opportunistic */}

    final paths = await _resolvePaths(spec);
    final needsEspeak = !File('${paths.dataDir}/$_espeakMarker').existsSync();
    final files = [...spec.files, if (needsEspeak) _config.espeakData];

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
        throw TtsVoiceDownloadException(
          'La descarga de la voz neuronal no se completó (${result.status.name}).',
        );
      }
      await _verifySize(await task.filePath(), file);
    }

    await _writeTokens(spec, paths);
    if (needsEspeak) await _extractEspeakData(paths);

    if (onProgress != null) onProgress(1.0);
    return paths;
  }

  /// Derives `*.tokens.txt` from the downloaded `*.onnx.json` so sherpa-onnx
  /// gets the token table its converted piper models expect.
  Future<void> _writeTokens(TtsVoiceSpec spec, TtsVoicePaths paths) async {
    final configPath = await _taskFor(spec.config).filePath();
    try {
      final tokens = piperTokensFromConfigJson(await File(configPath).readAsString());
      await File(paths.tokens).writeAsString(tokens, flush: true);
    } on PiperTokensException {
      rethrow;
    } catch (e) {
      throw TtsVoiceDownloadException('No se pudo preparar la tabla de fonemas: $e');
    }
  }

  /// Extracts espeak-ng-data.tar.gz next to the models, verifies the marker
  /// file landed, and deletes the archive to reclaim space.
  Future<void> _extractEspeakData(TtsVoicePaths paths) async {
    final archivePath = await _taskFor(_config.espeakData).filePath();
    final modelDir = File(paths.model).parent;
    await extractTarGz(archivePath, modelDir);
    if (!File('${paths.dataDir}/$_espeakMarker').existsSync()) {
      throw TtsVoiceDownloadException(
        'El paquete espeak-ng-data no contenía "$_espeakMarker"; descarga descartada.',
      );
    }
    try {
      await File(archivePath).delete();
    } catch (_) {/* best effort — extraction already succeeded */}
  }

  /// Verify the file at [path] is at least [file.minBytes]. Deletes it and
  /// throws on failure so a truncated/bogus file can never be used.
  Future<void> _verifySize(String path, TtsVoiceFile file) async {
    final onDisk = File(path);
    int length;
    try {
      length = await onDisk.length();
    } catch (_) {
      throw TtsVoiceDownloadException('No se pudo leer "${file.name}" tras la descarga.');
    }
    if (length < file.minBytes) {
      try {
        await onDisk.delete();
      } catch (_) {/* best effort — the size failure is what matters */}
      throw TtsVoiceDownloadException('La verificación de "${file.name}" falló; descarga descartada.');
    }
  }

  Future<TtsVoicePaths> _resolvePaths(TtsVoiceSpec spec) async {
    final model = await _taskFor(spec.model).filePath();
    final dir = File(model).parent.path;
    return TtsVoicePaths(
      model: model,
      tokens: '$dir/${spec.tokensFileName}',
      dataDir: '$dir/${TtsVoiceSourceConfig.espeakDataDirName}',
    );
  }

  static String _joinUrl(String base, String name) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$name';
  }
}
