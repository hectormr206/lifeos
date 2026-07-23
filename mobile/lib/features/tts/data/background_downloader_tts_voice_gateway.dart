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

  /// The downloader group for [voiceId]'s tasks — DERIVED PER VOICE so the
  /// defensive `reset(group:)` at the start of a download only clears THAT
  /// voice's own stale/failed tasks and never cancels a sibling voice that is
  /// downloading concurrently (a single shared group made starting voice B
  /// reset voice A's in-flight task, freezing both). Non-alphanumeric id chars
  /// are sanitized so the group is a stable, valid identifier.
  static String groupForVoice(String voiceId) =>
      '${_group}_${voiceId.replaceAll(RegExp('[^A-Za-z0-9]'), '_')}';

  DownloadTask _taskFor(TtsVoiceFile file, String group) => DownloadTask(
        url: _joinUrl(_config.baseUrl, file.name),
        filename: file.name,
        group: group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _directory,
        updates: Updates.statusAndProgress,
      );

  @override
  Future<TtsVoicePaths?> installedVoice(String voiceId) async {
    if (voiceId.isEmpty) return null;
    final spec = _config.specForVoice(voiceId);
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
    String voiceId, {
    void Function(double progress)? onProgress,
  }) async {
    if (!_config.isConfigured) {
      throw TtsVoiceDownloadException('Origen de la voz neuronal no configurado.');
    }
    if (voiceId.isEmpty) {
      throw TtsVoiceDownloadException('No se indicó ninguna voz para descargar.');
    }
    final spec = _config.specForVoice(voiceId);
    final group = groupForVoice(voiceId);

    // Clear any stale/failed task record for THIS VOICE's group first (same
    // defensive reset the STT + app-update downloads use to avoid a re-attach
    // loop). Scoped per voice so a concurrent sibling download is never reset.
    try {
      await _downloader.reset(group: group);
    } catch (_) {/* opportunistic */}

    final paths = await _resolvePaths(spec);
    final needsEspeak = !File('${paths.dataDir}/$_espeakMarker').existsSync();
    final files = [...spec.files, if (needsEspeak) _config.espeakData];

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final task = _taskFor(file, group);
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

    await _writeTokens(spec, paths, group);
    if (needsEspeak) await _extractEspeakData(paths, group);

    if (onProgress != null) onProgress(1.0);
    return paths;
  }

  /// Derives `*.tokens.txt` from the downloaded `*.onnx.json` so sherpa-onnx
  /// gets the token table its converted piper models expect.
  Future<void> _writeTokens(
    TtsVoiceSpec spec,
    TtsVoicePaths paths,
    String group,
  ) async {
    final configPath = await _taskFor(spec.config, group).filePath();
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
  /// file landed, and deletes the archive to reclaim space. Idempotent: if a
  /// concurrent voice download already extracted the shared data (marker
  /// present), it skips re-extracting so two downloads never race on the dir.
  Future<void> _extractEspeakData(TtsVoicePaths paths, String group) async {
    if (File('${paths.dataDir}/$_espeakMarker').existsSync()) return;
    final archivePath = await _taskFor(_config.espeakData, group).filePath();
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

  @override
  Future<void> deleteVoice(String voiceId) async {
    if (voiceId.isEmpty) return;
    final spec = _config.specForVoice(voiceId);
    // Only this voice's OWN files — model, Piper config, derived tokens. The
    // shared espeak-ng-data dir stays: every other installed voice needs it.
    final configPath = await _taskFor(spec.config, _group).filePath();
    final paths = await _resolvePaths(spec);
    for (final path in [paths.model, configPath, paths.tokens]) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {/* best effort per file — a missing file is already "gone" */}
    }
  }

  // The group here is irrelevant: [DownloadTask.filePath] is derived from the
  // base directory + filename, not the group, so path resolution is stable.
  Future<TtsVoicePaths> _resolvePaths(TtsVoiceSpec spec) async {
    final model = await _taskFor(spec.model, _group).filePath();
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
