/// On-device text-embedding seam (roadmap SLICE B1: local embeddings + RAG).
///
/// This is the ONLY abstraction the RAG layer depends on — the concrete
/// `flutter_gemma` embedding backend lives behind `GemmaEmbedder`
/// (features/embedding/data) so:
///   * `RagService`, the graph vector store, and their tests are exercisable
///     with a `FakeTextEmbedder` (no ~300MB download, no real model, no device),
///     and
///   * the embedding model/backend can be swapped without touching callers.
///
/// The embedder is a SEPARATE model instance from the chat LLM. To keep only
/// ONE hot model in RAM at generation time ("load-around-the-turn"), embed +
/// [dispose] the embedder BEFORE loading the LLM for the turn (or vice-versa);
/// see `GemmaEmbedder` for the intended usage.
library;

import 'dart:typed_data';

/// Contract for a locally-runnable text embedder. Implemented for real by
/// `GemmaEmbedder` (EmbeddingGemma-300M); faked in tests.
abstract class TextEmbedder {
  /// Stable identifier of the embedding model + configuration, stored on every
  /// vector row so recall can filter to one model and NEVER compare across
  /// models (graph caveat R8). Changing the model/dim MUST change this string.
  String get model;

  /// Output dimensionality of [embed] (e.g. 512 after MRL truncation).
  int get dimension;

  /// Embed [text] into a [dimension]-length float32 vector.
  ///
  /// [isQuery] selects the task prefix EmbeddingGemma was trained with:
  ///   * `true`  → query embedding (for a search query), and
  ///   * `false` → document embedding (for a stored/indexed node).
  /// Query and document vectors of the SAME model are directly comparable by
  /// cosine; that asymmetry is what makes retrieval accurate.
  Future<Float32List> embed(String text, {bool isQuery = false});

  /// Release the loaded embedding model + native handles, freeing its RAM.
  /// Safe to call when nothing is loaded. Call this before loading the LLM so
  /// the LLM is the only hot model during a generation turn.
  Future<void> dispose();
}
