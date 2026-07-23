/// Real, on-device [TextEmbedder] backed by flutter_gemma's native embedding
/// API (roadmap SLICE B1, activated in B1b). Everything plugin-specific is
/// confined here; the RAG layer only ever sees [TextEmbedder].
///
/// API (verified against flutter_gemma 1.3.1 sources):
///   install: `FlutterGemma.installEmbedder()
///     .modelFromFile(path).tokenizerFromFile(path).install()`  → auto-sets the
///     active embedding model (idempotent: an already-installed file pair is
///     just re-activated).
///   load:    `FlutterGemma.getActiveEmbedder()`  → EmbeddingModel
///   embed:   `model.generateEmbedding(text, taskType:)`  → `List<double>`
///   dispose: `model.close()`
///
/// EMBEDDING-BACKEND REGISTRATION: flutter_gemma core registers NO embedding
/// backend by default — the native LiteRT runtime lives in the separate
/// `flutter_gemma_embeddings` package (its `LiteRtEmbeddingBackend` implements
/// `EmbeddingBackendProvider`). Production registers it once via
/// `FlutterGemma.initialize(embeddingBackends: [LiteRtEmbeddingBackend()])`;
/// without it the first `getActiveEmbedder`/`generateEmbedding` throws a clear
/// "add the embeddings package" StateError. That registration is injected as
/// the [initializer] seam (see data/flutter_gemma_embedding_backend.dart) so
/// this file needs no dependency on the backend package and tests never touch
/// a plugin channel. The default here is a bare `FlutterGemma.initialize()` so
/// this class compiles and stays testable.
///
/// MODEL FILES: the ~179 MB EmbeddingGemma weights are NOT fetched from the
/// (license-gated) HuggingFace repo at runtime — the [pathsLoader] seam
/// resolves the files the [EmbedModelGateway] downloaded from the VPS on first
/// use. While the gateway reports "not installed" (loader → null) [embed]
/// throws a [StateError]; C1's chat context builder catches ANY embed failure
/// and falls back to lexical recall, so semantic recall simply stays dormant
/// until the download lands.
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

import '../domain/embed_model.dart';
import '../domain/text_embedder.dart';

/// Immutable config for the on-device embedder. Defaults to EmbeddingGemma-300M
/// truncated to 512 dims (MRL).
class EmbedderConfig {
  const EmbedderConfig({this.dimension = 512});

  /// Native output width of EmbeddingGemma-300M before MRL truncation.
  static const int nativeDimension = 768;

  /// Stable model identifier persisted on every vector row (caveat R8). Encodes
  /// BOTH the model and the truncated dim so a future dim/model change is a new,
  /// non-comparable key rather than a silent corpus mismatch.
  String get modelKey => 'embeddinggemma-300m@$dimension';

  /// Truncated (MRL) output width used by the app. Must be ≤ [nativeDimension].
  final int dimension;
}

/// Resolves the on-disk model files, or null while they are not downloaded yet.
typedef EmbedModelPathsLoader = Future<EmbedModelPaths?> Function();

/// [TextEmbedder] over the unified `flutter_gemma` embedding API.
class GemmaEmbedder implements TextEmbedder {
  GemmaEmbedder(
    this._config, {
    required this._pathsLoader,
    Future<void> Function()? initializer,
  }) : _initializer = initializer ?? _defaultInitializer;

  /// Bare init seam — production overrides this with
  /// `registerLiteRtEmbeddingBackend` (data/flutter_gemma_embedding_backend.dart),
  /// which also registers `LiteRtEmbeddingBackend()` from
  /// `flutter_gemma_embeddings`.
  static Future<void> _defaultInitializer() => FlutterGemma.initialize();

  final EmbedderConfig _config;
  final EmbedModelPathsLoader _pathsLoader;
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

  /// Single-flight install/activate of the downloaded weights + tokenizer.
  /// A FAILED attempt (e.g. files not downloaded yet) clears the cached future
  /// so a later call retries once the gateway has the files.
  Future<void> _ensureInstalled() async {
    final inFlight = _installFuture;
    if (inFlight != null) return inFlight;
    final attempt = _install();
    _installFuture = attempt;
    try {
      await attempt;
    } catch (_) {
      _installFuture = null;
      rethrow;
    }
  }

  Future<void> _install() async {
    await _ensureInitialized();
    final paths = await _pathsLoader();
    if (paths == null) {
      throw StateError(
        'Embedding model not downloaded yet — semantic recall stays dormant.',
      );
    }
    await FlutterGemma.installEmbedder()
        .modelFromFile(paths.model)
        .tokenizerFromFile(paths.tokenizer)
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
