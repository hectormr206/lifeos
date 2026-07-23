/// On-device LLM engine seam (roadmap SLICE 1: run gemma-4-E2B fully offline
/// behind the existing chat UI).
///
/// This is the ONLY abstraction the rest of the app depends on — the concrete
/// `flutter_gemma` dependency lives behind [FlutterGemmaLlmEngine]
/// (features/local_model/data) so:
///   * the chat flow is unit-testable with a `FakeLocalLlmEngine` (no 2.5GB
///     download, no real inference, no device), and
///   * the backend/model can be swapped (GPU today, Pixel Tensor-G5 NPU later)
///     without touching callers.
library;

import 'dart:typed_data';

import 'generation_metrics.dart';

export 'generation_metrics.dart';

/// Hardware backend the on-device model runs on. Maps 1:1 to flutter_gemma's
/// `PreferredBackend` inside [FlutterGemmaLlmEngine]; kept as our own enum so
/// the domain layer never imports the plugin.
enum LocalLlmBackend { cpu, gpu, npu }

/// Immutable config for the on-device model. Defaults to the public,
/// token-free gemma-4-E2B litert-lm build on the GPU backend.
///
/// SLICE 1 scope: text-only, non-streaming, Android-only. The Pixel
/// Tensor-G5 NPU build is wired as [pixelNpuModelUrl] + [LocalLlmBackend.npu]
/// so it can be tried on-device later by swapping this config — see the
/// roadmap. TODO(roadmap): vision / audio / streaming / RAG variants.
class LocalModelConfig {
  const LocalModelConfig({
    this.modelUrl = defaultModelUrl,
    this.backend = LocalLlmBackend.gpu,
    this.maxTokens = 4096,
    this.maxOutputTokens = 512,
  });

  /// BENCHMARK-TUNED sampling for gemma-4-E2B, straight from our `model_audit`
  /// tune-to-peak recipe (the authoritative per-role sweep). These are the tuned
  /// values for BOTH the vision role AND the general/text roles — the same
  /// setting peaked quality for both (only the longsum role differs, which this
  /// app does not use). They REPLACE the old guessed values (vision was at an
  /// arbitrary 0.7/40/0.9 that degenerated → emitted `<pad>` → blank bubble).
  /// Passed to every `createChat` unless a caller overrides them (see the
  /// escape-temp retry in OnDeviceChatRepository).
  static const double tunedTemperature = 0.6;
  static const int tunedTopK = 20;
  static const double tunedTopP = 0.95;

  /// ESCAPE sampling: the higher-entropy config empirically proven to still
  /// produce output on the phone's litertlm backend when the tuned low-temp
  /// recipe degenerates to empty. Used only as a one-shot retry, never the
  /// default — the tuned recipe is preferred for quality.
  static const double escapeTemperature = 1.0;
  static const int escapeTopK = 64;
  static const double escapeTopP = 0.95;

  /// Max photos the model accepts per turn. flutter_gemma's native `.litertlm`
  /// FFI path supports several images in a single query (accumulated into one
  /// turn), but only up to the `maxNumImages` the model was created with — and
  /// vision must be enabled at model-creation time. Mirrors flutter_gemma's own
  /// example default of 4; used both when loading the model (as `maxNumImages`)
  /// and to cap the compose-area attach UI so the two never disagree.
  static const int maxImagesPerMessage = 4;

  /// gemma-4-E2B-it litert-lm, GPU-friendly build (2.59GB, apache-2.0, no
  /// HuggingFace token required).
  static const String defaultModelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

  /// Pixel Tensor-G5 NPU build. Pair with [LocalLlmBackend.npu]. Left as a
  /// documented, opt-in swap target for the on-device NPU experiment.
  static const String pixelNpuModelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_Google_Tensor_G5.litertlm';

  /// Where the weights are fetched from (network install).
  final String modelUrl;

  /// Preferred hardware backend for inference.
  final LocalLlmBackend backend;

  /// Max context window handed to the model at load.
  final int maxTokens;

  /// Cap on GENERATED tokens per reply (keeps latency bounded on-device).
  final int maxOutputTokens;

  /// The on-disk model filename flutter_gemma keys installation state on —
  /// the last path segment of [modelUrl] (e.g. `gemma-4-E2B-it.litertlm`).
  String get modelId => Uri.parse(modelUrl).pathSegments.last;
}

/// Contract for a locally-runnable LLM. Implemented for real by
/// [FlutterGemmaLlmEngine]; faked in tests.
abstract class LocalLlmEngine {
  /// Whether the weights are already downloaded + installed on this device.
  Future<bool> isModelInstalled();

  /// Downloads + installs the weights, emitting fractional progress in
  /// `0.0..1.0` and completing (with a final `1.0`) once installed. Errors
  /// on the stream surface a failed/cancelled download.
  ///
  /// LEGACY fallback path: used only when the self-hosted brain-model OTA
  /// source (`BRAIN_MODEL_BASE_URL`) is not configured. The OTA path instead
  /// downloads + sha256-verifies the file itself and hands the local path to
  /// [installModelFromFile].
  Stream<double> downloadModel();

  /// Registers an ALREADY-DOWNLOADED, ALREADY-VERIFIED weights file at
  /// [path] as the active model (the brain-model OTA install/swap step —
  /// flutter_gemma's `installModel().fromFile()`). Any loaded model is
  /// released first so an update can swap the file underneath.
  ///
  /// NOTE: a `fromFile` install registers the EXTERNAL path — flutter_gemma's
  /// `uninstallModel` will NOT delete that file, so the OTA gateway owns the
  /// file's lifecycle (`BrainModelUpdateGateway.deleteLocalFile`).
  Future<void> installModelFromFile(String path);

  /// Loads the installed weights into memory, ready for [generate].
  /// [backend] overrides the engine's configured default for this load.
  Future<void> load({LocalLlmBackend? backend});

  /// Runs one non-streaming completion for [prompt] and returns the reply
  /// text together with its [GenerationMetrics] (tokens/s, latency, backend).
  /// SLICE 1 is single-turn (no retained conversation history).
  ///
  /// [temperature]/[topK]/[topP] override the BENCHMARK-TUNED sampling
  /// ([LocalModelConfig.tuned*]) for this call only — used by the escape-temp
  /// retry when the tuned recipe degenerates to empty. Omit for the tuned path.
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  });

  /// Runs one non-streaming multimodal completion for [prompt] together with
  /// one or more attached [images] (JPEG/PNG), all sent within a single turn.
  /// Requires the loaded model variant to support vision; implementations that
  /// cannot run vision (or whose installed weights are text-only) MUST throw so
  /// the caller can degrade gracefully with a clear message rather than silently
  /// dropping the photos. [images] must not be empty.
  ///
  /// Real vision inference is arm64/Pixel-only (gemma-4-E2B multimodal build);
  /// the x86_64 emulator can exercise only the attach/UI flow, not inference.
  ///
  /// [temperature]/[topK]/[topP] override the BENCHMARK-TUNED sampling
  /// ([LocalModelConfig.tuned*]) for this call only — used by the escape-temp
  /// retry when the tuned recipe degenerates to empty. Omit for the tuned path.
  Future<GenerationResult> generateWithImages(
    String prompt,
    List<Uint8List> images, {
    double? temperature,
    int? topK,
    double? topP,
  });

  /// Releases the loaded model + native handles. Safe to call when not
  /// loaded.
  Future<void> dispose();

  /// Deletes the installed weights from disk, freeing the ~2.6GB they occupy,
  /// so the model can be re-downloaded later. Implementations MUST unload any
  /// loaded model first (release the native handle) so the file is not locked.
  /// Safe to call when nothing is installed.
  Future<void> deleteModel();
}
