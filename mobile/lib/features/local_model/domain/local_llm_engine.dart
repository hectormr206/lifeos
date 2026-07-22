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
  Stream<double> downloadModel();

  /// Loads the installed weights into memory, ready for [generate].
  /// [backend] overrides the engine's configured default for this load.
  Future<void> load({LocalLlmBackend? backend});

  /// Runs one non-streaming completion for [prompt] and returns the reply
  /// text. SLICE 1 is single-turn (no retained conversation history).
  Future<String> generate(String prompt);

  /// Releases the loaded model + native handles. Safe to call when not
  /// loaded.
  Future<void> dispose();
}
