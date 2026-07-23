/// Real, on-device [TextEmbedder] backed by flutter_gemma's native embedding
/// API (roadmap SLICE B1). Everything plugin-specific is confined here; the RAG
/// layer only ever sees [TextEmbedder].
///
/// API (verified against flutter_gemma 1.3.1 sources — the
/// `flutter_gemma_embeddings` add-on shape):
///   install: `FlutterGemma.installEmbedder()
///     .modelFromNetwork(modelUrl, token).tokenizerFromNetwork(tokenizerUrl,
///     token).install()`  → auto-sets the active embedding model.
///   load:    `FlutterGemma.getActiveEmbedder(preferredBackend)`  → EmbeddingModel
///   embed:   `model.generateEmbedding(text, taskType:)`  → `List<double>`
///   dispose: `model.close()`
///
/// EMBEDDING-BACKEND REGISTRATION: flutter_gemma core registers NO embedding
/// backend by default — the native runtime lives in the separate
/// `flutter_gemma_embeddings` package (its `LiteRtEmbeddingBackend` implements
/// `EmbeddingBackendProvider`). Production MUST register it once via
/// `FlutterGemma.initialize(embeddingBackends: [LiteRtEmbeddingBackend()])`;
/// without it the first `getActiveEmbedder`/`generateEmbedding` throws a clear
/// "add the embeddings package" StateError. That registration is injected as
/// the [initializer] seam (kept swappable so this file needs no dependency on
/// the backend package and tests never touch a plugin channel). The app wires a
/// concrete initializer at startup (a disjoint slice); the default here is a
/// bare `FlutterGemma.initialize()` so this class compiles and stays testable.
///
/// MRL (Matryoshka) TRUNCATION: EmbeddingGemma-300M emits [nativeDimension]
/// (768) values; we keep the first [dimension] (512). MRL guarantees the leading
/// slice is itself a valid, higher-signal-per-byte embedding, and cosine is
/// scale-invariant, so truncation needs no re-normalisation for recall.
///
/// RAM load-around-the-turn: the embedder is a SEPARATE model from the chat LLM.
/// Call [dispose] to free its native handle/RAM before loading the LLM for a
/// generation turn, so only one model is hot at a time on-device.
library;

import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../domain/text_embedder.dart';

/// Immutable config for the on-device embedder. Defaults to EmbeddingGemma-300M
/// truncated to 512 dims (MRL).
class EmbedderConfig {
  const EmbedderConfig({
    this.modelUrl = defaultModelUrl,
    this.tokenizerUrl = defaultTokenizerUrl,
    this.dimension = 512,
    this.huggingFaceToken,
  });

  /// EmbeddingGemma-300M weights (gated on HuggingFace → [huggingFaceToken]).
  static const String defaultModelUrl =
      'https://huggingface.co/google/embeddinggemma-300m/resolve/main/model.tflite';

  /// Matching SentencePiece tokenizer.
  static const String defaultTokenizerUrl =
      'https://huggingface.co/google/embeddinggemma-300m/resolve/main/sentencepiece.model';

  /// Native output width of EmbeddingGemma-300M before MRL truncation.
  static const int nativeDimension = 768;

  /// Stable model identifier persisted on every vector row (caveat R8). Encodes
  /// BOTH the model and the truncated dim so a future dim/model change is a new,
  /// non-comparable key rather than a silent corpus mismatch.
  String get modelKey => 'embeddinggemma-300m@$dimension';

  final String modelUrl;
  final String tokenizerUrl;

  /// Truncated (MRL) output width used by the app. Must be ≤ [nativeDimension].
  final int dimension;

  /// Optional HuggingFace token for the gated EmbeddingGemma download.
  final String? huggingFaceToken;
}

/// [TextEmbedder] over the unified `flutter_gemma` embedding API.
class GemmaEmbedder implements TextEmbedder {
  GemmaEmbedder(
    this._config, {
    Future<void> Function()? initializer,
  }) : _initializer = initializer ?? _defaultInitializer;

  /// Bare init seam — production overrides this with one that also registers
  /// `LiteRtEmbeddingBackend()` from `flutter_gemma_embeddings`.
  static Future<void> _defaultInitializer() => FlutterGemma.initialize();

  final EmbedderConfig _config;
  final Future<void> Function() _initializer;

  Future<void>? _initFuture;
  Future<void>? _installFuture;
  EmbeddingModel? _model;

  @override
  String get model => _config.modelKey;

  @override
  int get dimension => _config.dimension;

  /// One-shot idempotent plugin init (registers the embedding backend).
  Future<void> _ensureInitialized() => _initFuture ??= _initializer();

  /// One-shot idempotent download+activate of the embedder weights + tokenizer.
  Future<void> _ensureInstalled() => _installFuture ??= _install();

  Future<void> _install() async {
    await _ensureInitialized();
    if (FlutterGemma.hasActiveEmbedder()) return;
    await FlutterGemma.installEmbedder()
        .modelFromNetwork(_config.modelUrl, token: _config.huggingFaceToken)
        .tokenizerFromNetwork(
          _config.tokenizerUrl,
          token: _config.huggingFaceToken,
        )
        .install();
  }

  /// Lazily loads (once) the active embedding model into memory.
  Future<EmbeddingModel> _ensureLoaded() async {
    await _ensureInstalled();
    return _model ??= await FlutterGemma.getActiveEmbedder();
  }

  @override
  Future<Float32List> embed(String text, {bool isQuery = false}) async {
    final model = await _ensureLoaded();
    final raw = await model.generateEmbedding(
      text,
      taskType: isQuery ? TaskType.retrievalQuery : TaskType.retrievalDocument,
    );
    return _truncate(raw, _config.dimension);
  }

  /// Keep the leading [dim] values (MRL) and copy into a Float32List. If the
  /// model returns fewer than [dim] values, keep them all (no zero-padding —
  /// a shorter vector stays internally consistent for cosine).
  static Float32List _truncate(List<double> raw, int dim) {
    final n = dim <= raw.length ? dim : raw.length;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = raw[i];
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    if (model != null) await model.close();
  }
}
