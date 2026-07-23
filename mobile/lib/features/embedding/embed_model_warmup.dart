/// Warmup lifecycle for the on-device embedding model (roadmap SLICE B1b).
///
/// Semantic recall is DORMANT until the ~179 MB EmbeddingGemma model is on
/// disk. This notifier turns it on end-to-end, silently and off the critical
/// path:
///   1. probe the [EmbedModelGateway] — already installed → ready;
///   2. else download on first use from the VPS (progress in [state]);
///   3. once ready, BACKFILL: vector-index every existing `fact` node that has
///      no vector yet ([RagService.backfillMissingVectors]), then dispose the
///      embedder so its RAM is free before the next LLM turn.
///
/// [ensureStarted] is fired (unawaited) from the same places the app warms the
/// LLM and resolves the chat context deps; every step is best-effort — any
/// failure leaves recall on C1's lexical fallback and a later call retries.
/// There is deliberately NO Settings affordance this slice.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/rag_service.dart';
import 'embedding_providers.dart';

/// Availability of the on-device embedding model.
enum EmbedModelWarmupStatus {
  /// Not probed/downloaded yet — semantic recall dormant (lexical fallback).
  idle,

  /// The model files are downloading; [EmbedModelWarmupState.progress] is 0..1.
  downloading,

  /// Model on disk — semantic recall live (backfill may still be running).
  ready,

  /// The last attempt failed; a later [EmbedModelWarmupNotifier.ensureStarted]
  /// retries. Recall stays lexical meanwhile.
  failed,
}

/// Immutable warmup state (status + download progress for a future UI).
class EmbedModelWarmupState {
  const EmbedModelWarmupState({
    this.status = EmbedModelWarmupStatus.idle,
    this.progress = 0,
  });

  final EmbedModelWarmupStatus status;

  /// Aggregate download progress 0..1 (meaningful while [status] is
  /// [EmbedModelWarmupStatus.downloading]).
  final double progress;

  bool get isReady => status == EmbedModelWarmupStatus.ready;
}

class EmbedModelWarmupNotifier extends Notifier<EmbedModelWarmupState> {
  Future<void>? _run;

  /// Lets tests await the in-flight warmup deterministically.
  Future<void> get done => _run ?? Future<void>.value();

  @override
  EmbedModelWarmupState build() => const EmbedModelWarmupState();

  /// Kick the warmup once (single-flight). Safe to fire-and-forget from the
  /// LLM warm path and the per-turn chat deps loader: while a run is in flight
  /// (or has succeeded) this is a no-op; after a FAILED run the next call
  /// retries.
  Future<void> ensureStarted() {
    if (state.isReady) return Future<void>.value();
    return _run ??= _warmUp();
  }

  Future<void> _warmUp() async {
    try {
      final gateway = ref.read(embedModelGatewayProvider);
      var paths = await gateway.installedModel();
      if (paths == null) {
        final config = ref.read(embedModelSourceConfigProvider);
        if (!config.isConfigured) {
          // No source to fetch from — stay dormant without an error state.
          _run = null;
          return;
        }
        state = const EmbedModelWarmupState(
          status: EmbedModelWarmupStatus.downloading,
        );
        paths = await gateway.download(
          onProgress: (p) => state = EmbedModelWarmupState(
            status: EmbedModelWarmupStatus.downloading,
            progress: p,
          ),
        );
      }
      state = const EmbedModelWarmupState(
        status: EmbedModelWarmupStatus.ready,
        progress: 1,
      );
      await _backfill();
    } catch (_) {
      // Best-effort: a failed download/probe leaves recall lexical; clear the
      // single-flight slot so the next warm trigger retries.
      state = const EmbedModelWarmupState(status: EmbedModelWarmupStatus.failed);
      _run = null;
    }
  }

  /// Vector-index the facts recorded while the embedder was dormant, then free
  /// the embedder's RAM (load-around-the-turn). Best-effort by design.
  Future<void> _backfill() async {
    RagService? rag;
    try {
      final service = await ref.read(ragServiceProvider.future);
      rag = service;
      await service.backfillMissingVectors();
    } catch (_) {
      // The graph DB may still be opening or an embed may fail mid-batch —
      // whatever WAS indexed stays; the rest is picked up on a later warmup.
    } finally {
      try {
        await rag?.embedder.dispose();
      } catch (_) {/* dispose must never surface */}
    }
  }
}

/// The embed-model warmup state; fire `ensureStarted()` on the notifier from
/// LLM-warm / first-recall call sites.
final embedModelWarmupProvider =
    NotifierProvider<EmbedModelWarmupNotifier, EmbedModelWarmupState>(
  EmbedModelWarmupNotifier.new,
);
