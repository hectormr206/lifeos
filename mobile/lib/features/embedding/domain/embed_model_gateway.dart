import 'embed_model.dart';

/// Manages the on-device embedding model's lifecycle (roadmap SLICE B1b):
/// checking whether it is already downloaded and fetching it on first use.
/// Confines `background_downloader` + the filesystem to the edge so the warmup
/// and RAG flows are testable with a fake — the exact shape of the STT model
/// gateway (features/stt/domain/stt_model_gateway.dart).
abstract class EmbedModelGateway {
  /// The resolved [EmbedModelPaths] when every model file is present on disk,
  /// or `null` when the model still needs to be downloaded. Never throws — a
  /// probe failure reads as "not installed".
  Future<EmbedModelPaths?> installedModel();

  /// Downloads the model (all files) into the app-support dir, verifying each
  /// file's size after it lands. Emits progress in 0.0..1.0 via [onProgress].
  /// Returns the resolved [EmbedModelPaths] on success; throws on an
  /// unconfigured source, a failed download, or a size sanity-check failure.
  Future<EmbedModelPaths> download({void Function(double progress)? onProgress});
}
