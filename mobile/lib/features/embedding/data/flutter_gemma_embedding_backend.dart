/// Production plugin bootstrap for the EMBEDDING side of flutter_gemma
/// (roadmap SLICE B1b) — the counterpart of
/// features/local_model/data/flutter_gemma_llm_engine.dart's inference-engine
/// registration.
///
/// flutter_gemma's core registers NO embedding backend by default: the LiteRT
/// C-API runtime that actually executes EmbeddingGemma-300M lives in the
/// separate `flutter_gemma_embeddings` package. Its `LiteRtEmbeddingBackend`
/// must be registered once via
/// `FlutterGemma.initialize(embeddingBackends: [LiteRtEmbeddingBackend()])` or
/// the first `getActiveEmbedder`/`generateEmbedding` throws a StateError.
///
/// This is the ONLY file that imports `flutter_gemma_embeddings`; it is
/// injected into [GemmaEmbedder] as its `initializer` seam so the embedder
/// class itself (and its tests) never touch the plugin. `initialize()` is
/// additive — engines/backends registered by earlier calls (the LLM engine's
/// `LiteRtLmEngine`) are kept.
library;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';

/// Registers the LiteRT embedding backend (idempotent registry add).
Future<void> registerLiteRtEmbeddingBackend() => FlutterGemma.initialize(
      embeddingBackends: const [LiteRtEmbeddingBackend()],
    );
