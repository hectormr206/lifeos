import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../embedding/embed_model_warmup.dart';
import '../domain/idle_unload_llm_engine.dart';
import 'local_model_providers.dart';

/// Lifecycle of getting the on-device weights resident in RAM and ready for
/// inference.
///
/// The real scenario this exists for: the app is closed/backgrounded, the OS
/// evicts the model from memory (the weights file stays on disk — it is NOT
/// re-downloaded), and on the next launch the model must be re-initialised into
/// RAM. That takes a few seconds during which — before this — the chat gave the
/// user no feedback at all.
enum LocalModelLoadStatus {
  /// Nothing to load — cloud/HTTP chat mode is active (no on-device model).
  idle,

  /// The weights are being (re)initialised into memory.
  loading,

  /// The model is resident and ready for [LocalLlmEngine.generate].
  ready,

  /// Loading failed; [LocalModelLoadState.error] carries a neutral-Spanish
  /// message and the UI offers a retry.
  error,

  /// The model WAS resident and the engine released it to give the RAM back
  /// after an idle stretch ([IdleUnloadLlmEngine]).
  ///
  /// Distinct from [idle] on purpose: idle means there is no on-device model in
  /// play at all, this means there is one, installed and usable, simply not in
  /// memory right now. Sending stays enabled — the next message reloads it, and
  /// the banner returns while that happens.
  released,
}

/// Immutable UI state for the on-device model load.
class LocalModelLoadState {
  const LocalModelLoadState({this.status = LocalModelLoadStatus.idle, this.error});

  final LocalModelLoadStatus status;

  /// Neutral-Spanish failure message (only set when [status] is
  /// [LocalModelLoadStatus.error]).
  final String? error;

  bool get isLoading => status == LocalModelLoadStatus.loading;
  bool get isReady => status == LocalModelLoadStatus.ready;
  bool get hasError => status == LocalModelLoadStatus.error;
}

/// Surfaces the on-device model's load lifecycle so the chat screen can show a
/// clear "Cargando el modelo…" indicator and gate sending until the weights are
/// resident.
///
/// It only warms the engine when local mode is ON ([localModelEnabledProvider]).
/// In cloud/HTTP mode there is no model to load, so it stays [idle] and the chat
/// behaves exactly as before (no banner, send never gated). Because the engine's
/// `load()` is idempotent, this proactive warm-up and the repository's own lazy
/// load never do redundant work — whichever runs first fills the native handle
/// and the other returns instantly.
class LocalModelLoadNotifier extends Notifier<LocalModelLoadState> {
  Future<void>? _loadFuture;
  StreamSubscription<LlmResidency>? _residency;

  /// Lets tests await the in-flight load deterministically (mirrors the
  /// `ready` seam on the other notifiers).
  Future<void> get ready => _loadFuture ?? Future<void>.value();

  @override
  LocalModelLoadState build() {
    // Cloud/HTTP mode: nothing to load. Watching the toggle means flipping local
    // mode ON later rebuilds this notifier and kicks off the load.
    if (!ref.watch(localModelEnabledProvider)) {
      return const LocalModelLoadState();
    }
    // The engine owns residency and can release the weights on its own (the
    // desktop idle unload). Follow it instead of remembering a "ready" that
    // stopped being true while nobody was watching.
    final engine = ref.watch(localLlmEngineProvider);
    if (engine is IdleUnloadLlmEngine) {
      _residency = engine.residencyChanges.listen(_onResidency);
      ref.onDispose(() => _residency?.cancel());
    }
    _loadFuture = _load();
    return const LocalModelLoadState(status: LocalModelLoadStatus.loading);
  }

  void _onResidency(LlmResidency residency) {
    // A failed load owns the state until the user retries: an `unloaded` event
    // is exactly what that failure already reported, and overwriting it would
    // hide the error and its "Reintentar".
    if (state.hasError && residency != LlmResidency.loaded) return;
    state = switch (residency) {
      LlmResidency.loading => const LocalModelLoadState(status: LocalModelLoadStatus.loading),
      LlmResidency.loaded => const LocalModelLoadState(status: LocalModelLoadStatus.ready),
      LlmResidency.unloaded => const LocalModelLoadState(status: LocalModelLoadStatus.released),
    };
  }

  Future<void> _load() async {
    try {
      // No load-progress signal exists on the engine (flutter_gemma's
      // `getActiveModel` returns a bare Future), so the UI shows an indeterminate
      // spinner rather than a percentage.
      await ref.read(localLlmEngineProvider).load();
      state = const LocalModelLoadState(status: LocalModelLoadStatus.ready);
      // Same warm point, different model: kick the embedding-model warmup
      // (download-on-first-use + backfill) in the background. Best-effort —
      // semantic recall stays on C1's lexical fallback until it lands
      // (roadmap SLICE B1b).
      try {
        unawaited(ref.read(embedModelWarmupProvider.notifier).ensureStarted());
      } catch (_) {/* never let the memory warmup affect the LLM load */}
    } catch (error) {
      state = LocalModelLoadState(
        status: LocalModelLoadStatus.error,
        error: 'No se pudo cargar el modelo: $error',
      );
    }
  }

  /// Re-attempts a failed load (the banner's "Reintentar"). No-op while already
  /// loading or already ready.
  void retry() {
    if (state.isLoading || state.isReady) return;
    state = const LocalModelLoadState(status: LocalModelLoadStatus.loading);
    _loadFuture = _load();
  }
}

/// The on-device model load-state, watched by the chat screen for its
/// "Cargando el modelo…" banner and send gating.
final localModelLoadProvider =
    NotifierProvider<LocalModelLoadNotifier, LocalModelLoadState>(LocalModelLoadNotifier.new);
