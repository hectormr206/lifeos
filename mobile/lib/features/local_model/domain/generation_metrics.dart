import 'local_llm_engine.dart' show LocalLlmBackend;

/// Per-response performance metrics for ONE on-device generation
/// (roadmap SLICE 1 observability). Produced by [LocalLlmEngine.generate] /
/// `generateWithImage` and attached to the Axi [ChatMessage] so the chat UI can
/// show tokens/s + latency under the bubble and full stats in a modal.
///
/// HONESTY CONTRACT — what is measured vs estimated:
///   * [totalMs] is ALWAYS a real wall-clock measurement (Stopwatch around the
///     generate call) in [FlutterGemmaLlmEngine].
///   * [tokensOut] and [ttftMs] are taken from flutter_gemma's native
///     `SessionMetrics` when available. On the FFI/LiteRT-LM (.litertlm) path
///     these are ACCURATE native counts; when the runtime reports nothing
///     (e.g. an estimate-only backend) [tokensOut] falls back to a ~4-chars/
///     token heuristic and [tokensApproximate] is set true.
///   * [ttftMs] is null whenever the runtime did not report a time-to-first-
///     token (the non-streaming path may still surface it on FFI, but never
///     fabricates one).
///   * HTTP (non-local) chat carries NO metrics — the field stays null rather
///     than inventing numbers for a server round-trip.
class GenerationMetrics {
  const GenerationMetrics({
    required this.totalMs,
    required this.tokensOut,
    required this.backend,
    required this.modelId,
    this.ttftMs,
    this.tokensApproximate = false,
  });

  /// Wall-clock time for the whole generation, in milliseconds. Always real.
  final int totalMs;

  /// Number of tokens in the response. Native-accurate on FFI; a heuristic
  /// estimate (see [tokensApproximate]) when the runtime reports none.
  final int tokensOut;

  /// Hardware backend the model actually ran on for this generation.
  final LocalLlmBackend backend;

  /// The on-disk model filename that produced this response.
  final String modelId;

  /// Time-to-first-token in milliseconds, or null when the runtime did not
  /// report one (never fabricated).
  final int? ttftMs;

  /// True when [tokensOut] is a character-heuristic estimate rather than a
  /// native token count — surfaced in the UI so the number is not mistaken for
  /// an exact measurement.
  final bool tokensApproximate;

  /// Generation speed in tokens per (wall-clock) second — the headline metric.
  /// Zero when [totalMs] is zero (guards div-by-zero on a sub-millisecond run).
  double get tokensPerSec => totalMs > 0 ? tokensOut * 1000 / totalMs : 0;

  @override
  bool operator ==(Object other) =>
      other is GenerationMetrics &&
      other.totalMs == totalMs &&
      other.tokensOut == tokensOut &&
      other.backend == backend &&
      other.modelId == modelId &&
      other.ttftMs == ttftMs &&
      other.tokensApproximate == tokensApproximate;

  @override
  int get hashCode =>
      Object.hash(totalMs, tokensOut, backend, modelId, ttftMs, tokensApproximate);

  @override
  String toString() => 'GenerationMetrics(totalMs: $totalMs, tokensOut: $tokensOut, '
      'tokensPerSec: ${tokensPerSec.toStringAsFixed(1)}, ttftMs: $ttftMs, '
      'backend: $backend, modelId: $modelId, approx: $tokensApproximate)';
}

/// The result of one on-device generation: the reply [text] plus its
/// [metrics]. Returned by [LocalLlmEngine.generate] / `generateWithImage` so a
/// caller gets both the answer and how fast it was produced in one value.
class GenerationResult {
  const GenerationResult({required this.text, required this.metrics});

  final String text;
  final GenerationMetrics metrics;
}
