/// Riverpod wiring for the on-device embedding + RAG layer (roadmap SLICE B1,
/// activated end-to-end in B1b).
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
import 'data/background_downloader_embed_model_gateway.dart';
import 'data/embed_model_source_config.dart';
import 'data/flutter_gemma_embedding_backend.dart';
import 'data/gemma_embedder.dart';
import 'domain/embed_model_gateway.dart';
import 'domain/rag_service.dart';
import 'domain/text_embedder.dart';

/// Where the embedding model is fetched from (VPS base URL + file manifest).
final embedModelSourceConfigProvider = Provider<EmbedModelSourceConfig>(
  (ref) => const EmbedModelSourceConfig(),
);

/// Manages the on-device embedding model files: probing whether they are
/// installed and downloading them on first use. Overridden with a fake in
/// tests (same seam as the STT model gateway).
final embedModelGatewayProvider = Provider<EmbedModelGateway>(
  (ref) => BackgroundDownloaderEmbedModelGateway(
    config: ref.watch(embedModelSourceConfigProvider),
  ),
);

/// Configuration for the on-device embedder (MRL dim → vector model key).
final embedderConfigProvider = Provider<EmbedderConfig>(
  (ref) => const EmbedderConfig(),
);

/// The app-wide text embedder (EmbeddingGemma-300M → 512 dims). Loads from the
/// gateway-downloaded files and registers `LiteRtEmbeddingBackend` on first
/// use; while the files are absent every embed throws and callers fall back to
/// lexical recall (C1). Its native handle is released on dispose so it doesn't
/// hold RAM alongside the LLM.
final textEmbedderProvider = Provider<TextEmbedder>((ref) {
  final embedder = GemmaEmbedder(
    ref.watch(embedderConfigProvider),
    pathsLoader: () => ref.read(embedModelGatewayProvider).installedModel(),
    initializer: registerLiteRtEmbeddingBackend,
  );
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
