/// Riverpod wiring for the on-device chat context builder (roadmap SLICE C1).
///
/// Bridges the pure [ChatContextBuilder] to the app's async providers: the graph
/// store ([localGraphStoreProvider]) and the RAG service ([ragServiceProvider])
/// both resolve lazily, and either may be unavailable (DB still opening, or the
/// embedding backend not registered). The [ChatContextDepsLoader] here resolves
/// them best-effort per turn:
///   * store unavailable  → deps null → memory OFF for this turn (chat still answers);
///   * embedder available → semantic recall + fact indexing;
///   * embedder absent    → deps.rag null → lexical recall, no indexing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../../../l10n/locale_providers.dart';
import '../../embedding/domain/rag_service.dart';
import '../../embedding/embedding_providers.dart';
import '../../memory/data/memory_writer.dart';
import '../domain/chat_context_builder.dart';

/// The app-wide context builder used by `chatRepositoryProvider`'s
/// `decoratePrompt` seam (preamble) and by `ChatNotifier` (memory write-back).
///
/// `read` (not `watch`) inside the loader so a language/clock/store change never
/// rebuilds this provider (which would drop nothing costly here, but keeps it
/// aligned with the repository's read-live-at-send-time contract).
final chatContextBuilderProvider = Provider<ChatContextBuilder>((ref) {
  return ChatContextBuilder(
    loadDeps: () async {
      try {
        final store = await ref.read(localGraphStoreProvider.future);
        RagService? rag;
        try {
          // Constructs the RAG service (embedder handle is lazy — no native load
          // until we actually embed, which the builder guards + falls back on).
          rag = await ref.read(ragServiceProvider.future);
        } catch (_) {
          rag = null; // Embedding stack unavailable → lexical-only recall.
        }
        return ChatContextDeps(
          store: store,
          writer: MemoryWriter(store),
          rag: rag,
        );
      } catch (_) {
        return null; // Graph store unavailable → no memory this turn.
      }
    },
    languageCode: () => ref.read(appLanguageCodeProvider),
    now: () => ref.read(clockProvider).now(),
  );
});
