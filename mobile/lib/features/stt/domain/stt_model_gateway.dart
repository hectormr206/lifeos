import 'stt_model.dart';

/// Manages the on-device Whisper model's lifecycle (roadmap slice B2): checking
/// whether it is already downloaded and fetching it on first use. Confines
/// `background_downloader` + the filesystem to the edge so the voice-note flow
/// is testable with a fake.
abstract class SttModelGateway {
  /// The resolved [SttModelPaths] when every model file is present on disk,
  /// or `null` when the model still needs to be downloaded. Never throws — a
  /// probe failure reads as "not installed".
  Future<SttModelPaths?> installedModel();

  /// Downloads the model (all files) into the app-support dir, verifying each
  /// file's size after it lands. Emits progress in 0.0..1.0 via [onProgress].
  /// Returns the resolved [SttModelPaths] on success; throws on an unconfigured
  /// source, a failed download, or a size sanity-check failure.
  Future<SttModelPaths> download({void Function(double progress)? onProgress});
}
