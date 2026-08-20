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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/clock/clock.dart';
import '../../../core/timezone/timezone_providers.dart';
import '../../../core/graph/graph_providers.dart';
import '../../../l10n/locale_providers.dart';
import '../../embedding/domain/rag_service.dart';
import '../../embedding/embed_model_warmup.dart';
import '../../embedding/embedding_providers.dart';
import '../../local_model/presentation/local_model_providers.dart';
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
        // Lazy first-recall trigger (roadmap SLICE B1b): nudge the embedding
        // model warmup (probe / download-on-first-use / backfill) without
        // blocking the turn. Single-flight + best-effort inside the notifier;
        // recall below still runs lexically until the model is ready.
        try {
          unawaited(
            ref.read(embedModelWarmupProvider.notifier).ensureStarted(),
          );
        } catch (_) {/* warmup must never affect the turn */}
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
          // On-device model for OPEN-ENDED relation extraction (best-effort;
          // the extractor loads/guards it and no-ops on any failure).
          engine: ref.read(localLlmEngineProvider),
        );
      } catch (_) {
        return null; // Graph store unavailable → no memory this turn.
      }
    },
    languageCode: () => ref.read(appLanguageCodeProvider),
    now: () => ref.read(clockProvider).now(),
    // Wall clock for the DETERMINISTIC sleep clock-math ("me dormí a las 12 am y
    // acabo de despertar"): the same instant, but reinterpreted in the user's
    // effective zone when they PINNED an override, so a 00:00 bedtime is
    // measured against the hour the user is actually living.
    //
    // Read SYNCHRONOUSLY off the already-resolved FutureProvider value: the
    // capture triage is sync, and until the zone resolves (or in AUTOMATIC mode)
    // device-local time is exactly the right answer — never a blocking await.
    wallClockNow: () {
      final base = ref.read(clockProvider).now();
      tz.Location? location;
      try {
        location =
            ref.read(effectiveTimezoneProvider).asData?.value.overrideLocation;
      } catch (_) {
        location = null; // Timezone stack unavailable → device-local.
      }
      return location == null ? base : tz.TZDateTime.from(base, location);
    },
    // The same read, for rendering hours the user reads. Same rationale: sync
    // off the resolved value, device-local until it lands.
    zoneLocation: () {
      try {
        return ref.read(effectiveTimezoneProvider).asData?.value.location;
      } catch (_) {
        return null;
      }
    },
  );
});
