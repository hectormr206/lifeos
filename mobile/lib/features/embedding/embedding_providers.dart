/// Riverpod wiring for the on-device embedding + RAG layer (roadmap SLICE B1).
///
/// The embedder is a SEPARATE model instance from the chat LLM. To keep only
/// ONE hot model in RAM during a generation turn ("load-around-the-turn"),
/// callers embed/index with the [textEmbedderProvider], then `dispose()` it
/// (freeing its native handle) BEFORE loading the LLM — or invalidate the
/// provider, which triggers the `onDispose` below.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/graph/local_graph_store.dart';
import '../../core/graph/graph_providers.dart';
import 'data/gemma_embedder.dart';
import 'domain/rag_service.dart';
import 'domain/text_embedder.dart';

/// Configuration for the on-device embedder (model URLs, MRL dim, HF token).
final embedderConfigProvider = Provider<EmbedderConfig>(
  (ref) => const EmbedderConfig(),
);

/// The app-wide text embedder (EmbeddingGemma-300M → 512 dims). Its native
/// handle is released on dispose so it doesn't hold RAM alongside the LLM.
final textEmbedderProvider = Provider<TextEmbedder>((ref) {
  final embedder = GemmaEmbedder(ref.watch(embedderConfigProvider));
  ref.onDispose(embedder.dispose);
  return embedder;
});

/// Composes the embedder with the (async) graph store into the RAG service.
/// Null while the encrypted graph DB is still opening.
final ragServiceProvider = FutureProvider<RagService>((ref) async {
  final LocalGraphStore store =
      await ref.watch(localGraphStoreProvider.future);
  final embedder = ref.watch(textEmbedderProvider);
  return RagService(embedder: embedder, store: store);
});
