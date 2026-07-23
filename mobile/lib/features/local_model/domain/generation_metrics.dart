import 'local_llm_engine.dart' show LocalLlmBackend;

/// Per-response performance metrics for ONE on-device generation
/// (roadmap SLICE 1 observability). Produced by [LocalLlmEngine.generate] /
/// `generateWithImages` and attached to the Axi [ChatMessage] so the chat UI can
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
    this.decodeTokensPerSec,
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

  /// The runtime's OWN average decode speed in tokens/second (flutter_gemma's
  /// native `SessionMetrics.tokensPerSecond`), or null when it did not report
  /// one. This is the TRUE decode rate — it excludes session init, prefill, and
  /// time-to-first-token — so [tokensPerSec] prefers it over any wall-clock
  /// estimate. Never fabricated.
  final double? decodeTokensPerSec;

  /// True when [tokensOut] is a character-heuristic estimate rather than a
  /// native token count — surfaced in the UI so the number is not mistaken for
  /// an exact measurement.
  final bool tokensApproximate;

  /// Generation speed in tokens per second — the headline metric.
  ///
  /// PREFERS the runtime's native decode rate ([decodeTokensPerSec]) when it is
  /// present: that is the true decode throughput and is NOT diluted by session
  /// init, prefill, or TTFT. When the runtime reports no decode rate, it falls
  /// back to a wall-clock estimate that STILL excludes the prefill/TTFT window
  /// (`tokensOut / ((totalMs - ttftMs) / 1000)`), never the raw
  /// `tokensOut / totalMs` (which counts init+prefill+TTFT as if it were decode
  /// and reads far too low). Zero when there is no positive decode window to
  /// divide by (guards div-by-zero on a sub-millisecond run).
  double get tokensPerSec {
    final native = decodeTokensPerSec;
    if (native != null && native > 0) return native;
    // Exclude the prefill/TTFT window from the denominator so the fallback
    // reflects decode speed, not end-to-end latency. A null TTFT contributes 0.
    final decodeMs = totalMs - (ttftMs ?? 0);
    if (decodeMs <= 0) return 0;
    return tokensOut * 1000 / decodeMs;
  }

  @override
  bool operator ==(Object other) =>
      other is GenerationMetrics &&
      other.totalMs == totalMs &&
      other.tokensOut == tokensOut &&
      other.backend == backend &&
      other.modelId == modelId &&
      other.ttftMs == ttftMs &&
      other.decodeTokensPerSec == decodeTokensPerSec &&
      other.tokensApproximate == tokensApproximate;

  @override
  int get hashCode => Object.hash(
      totalMs, tokensOut, backend, modelId, ttftMs, decodeTokensPerSec, tokensApproximate);

  @override
  String toString() => 'GenerationMetrics(totalMs: $totalMs, tokensOut: $tokensOut, '
      'tokensPerSec: ${tokensPerSec.toStringAsFixed(1)}, ttftMs: $ttftMs, '
      'backend: $backend, modelId: $modelId, approx: $tokensApproximate)';
}

/// The result of one on-device generation: the reply [text] plus its
/// [metrics]. Returned by [LocalLlmEngine.generate] / `generateWithImages` so a
/// caller gets both the answer and how fast it was produced in one value.
class GenerationResult {
  const GenerationResult({required this.text, required this.metrics});

  final String text;
  final GenerationMetrics metrics;
}
