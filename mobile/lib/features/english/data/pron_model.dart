// The phone model for pronunciation feedback: ZIPA-small CR-CTC, int8.
//
// Like Whisper it is not in the APK: 71 MB are fetched on first use from the
// same self-hosted base as the other models (`<UPDATE_BASE_URL>/pron`), over
// Wi-Fi only, and every device gets the same file. Unlike Whisper, the files
// are checked BYTE FOR BYTE (size and SHA-256), because these are exactly
// the files that were measured: native speech, controls and Spanish-accented
// reads (see the ODD doc). A different file would be an unmeasured model.
//
// Provenance: anyspeech/zipa-small-crctc-500k on Hugging Face, the ONNX
// export of the average of the ten Apache-2.0 checkpoints 464k–500k of
// anyspeech/zipa-cr-s (same author, Jian Zhu). See assets/english/NOTICE.md.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/network/heavy_download_policy.dart';
import '../../app_update/domain/update_source_config.dart';

/// Base URL of the phone model files; `--dart-define=PRON_MODEL_BASE_URL=…`
/// sets it at build time (tools/publish-*.sh derive it from the update base).
const String kPronModelBaseUrl = String.fromEnvironment(
  'PRON_MODEL_BASE_URL',
  defaultValue: 'https://models.PLACEHOLDER.example/lifeos/pron',
);

/// One model file: its name (remote and local), exact size and SHA-256.
class PronModelFile {
  const PronModelFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final int bytes;
  final String sha256;
}

class PronModelSourceConfig {
  const PronModelSourceConfig({
    this.baseUrl = kPronModelBaseUrl,
    this.model = const PronModelFile(
      name: 'zipa-small-crctc-500k.int8.onnx',
      bytes: 70677672,
      sha256: 'd0e28b68164e8b1fbd6105100c01798828aa0855000ce9bbbd1a2cec233adf13',
    ),
    this.tokens = const PronModelFile(
      name: 'zipa-small-crctc-500k.tokens.txt',
      bytes: 769,
      sha256: 'f8e042a0c9130532b22d03ec7cae2f75a23fbec70c450c31a8efb51787b2b8fe',
    ),
  });

  final String baseUrl;
  final PronModelFile model;
  final PronModelFile tokens;

  /// In download order.
  List<PronModelFile> get files => [model, tokens];

  /// False while the placeholder is in place: no download is attempted.
  bool get isConfigured =>
      baseUrl.isNotEmpty && !baseUrl.contains('PLACEHOLDER');
}

/// Whether [file] is exactly [expected]: size first (cheap), then SHA-256,
/// streamed in a worker isolate so 71 MB never sit in memory or block the UI.
Future<bool> verifyModelFile(File file, PronModelFile expected) async {
  if (!file.existsSync() || file.lengthSync() != expected.bytes) return false;
  final path = file.path;
  final digest = await Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString(),
  );
  return digest == expected.sha256;
}

class PronModelPaths {
  const PronModelPaths({required this.model, required this.tokens});
  final String model;
  final String tokens;
}

class PronModelDownloadException implements Exception {
  PronModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class PronModelGateway {
  /// The paths when both files are on disk at their exact size, else null.
  /// Never throws.
  Future<PronModelPaths?> installedModel();

  /// Fetches and verifies both files; progress 0..1. Throws on an
  /// unconfigured source, a failed download or a file that does not verify
  /// (which is deleted).
  Future<PronModelPaths> download({void Function(double progress)? onProgress});
}

class BackgroundDownloaderPronModelGateway implements PronModelGateway {
  BackgroundDownloaderPronModelGateway({
    this._config = const PronModelSourceConfig(),
    Future<Directory> Function()? directory,
    this._downloader,
  }) : _directory = directory ?? _defaultDirectory;

  final PronModelSourceConfig _config;
  final Future<Directory> Function() _directory;
  final FileDownloader? _downloader;

  static const String _group = 'pron_model';
  static const String _subdirectory = 'pron_model';

  static Future<Directory> _defaultDirectory() async => Directory(
        '${(await getApplicationSupportDirectory()).path}/$_subdirectory',
      );

  Future<PronModelPaths> _paths() async {
    final dir = (await _directory()).path;
    return PronModelPaths(
      model: '$dir/${_config.model.name}',
      tokens: '$dir/${_config.tokens.name}',
    );
  }

  @override
  Future<PronModelPaths?> installedModel() async {
    try {
      final paths = await _paths();
      for (final (path, file) in [
        (paths.model, _config.model),
        (paths.tokens, _config.tokens),
      ]) {
        final onDisk = File(path);
        if (!onDisk.existsSync() || onDisk.lengthSync() != file.bytes) {
          return null;
        }
      }
      return paths;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PronModelPaths> download({
    void Function(double progress)? onProgress,
  }) async {
    if (!_config.isConfigured) {
      throw PronModelDownloadException(
          'Origen del modelo de pronunciación no configurado.');
    }
    final downloader = _downloader ?? FileDownloader();
    try {
      await downloader.reset(group: _group);
    } catch (_) {/* opportunistic, as the other model downloads do */}

    final files = _config.files;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final task = DownloadTask(
        headers: {kUpdateAccessKeyHeader: kUpdateAccessKey},
        url: '${_config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/${file.name}',
        filename: file.name,
        group: _group,
        baseDirectory: BaseDirectory.applicationSupport,
        directory: _subdirectory,
        requiresWiFi: kHeavyDownloadsRequireWiFi,
      );
      final result = await downloader.download(
        task,
        onProgress: (p) {
          if (p >= 0 && onProgress != null) onProgress((i + p) / files.length);
        },
      );
      if (result.status != TaskStatus.complete) {
        throw PronModelDownloadException(
            'La descarga no se completó (${result.status.name}).');
      }
      final onDisk = File(await task.filePath());
      if (!await verifyModelFile(onDisk, file)) {
        try {
          await onDisk.delete();
        } catch (_) {/* the verification failure is what matters */}
        throw PronModelDownloadException(
            'La verificación de "${file.name}" falló; descarga descartada.');
      }
    }
    onProgress?.call(1);
    return _paths();
  }
}
