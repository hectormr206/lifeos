import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/local_llm_engine.dart';
import 'local_model_providers.dart';

/// The forced inference backend, or `null` for automatic (GPU-first with the
/// engine's own CPU fallback). Developer/benchmark affordance.
///
/// SYNCHRONOUS BY DESIGN. [localModelConfigProvider] is a plain `Provider` and
/// has to answer without awaiting, so this starts at `null` (automatic, the
/// behaviour the app had before this setting existed) and hydrates from
/// shared_preferences right after the first read. Nothing loads a 2.6GB model
/// in that window — the first load is user- or job-triggered — and the worst
/// case is the safe default.
class ForcedLocalModelBackendNotifier extends Notifier<LocalLlmBackend?> {
  Future<void>? _hydrated;
  bool _disposed = false;

  /// Set once the user has picked a backend, so a slow read of the stored value
  /// can never land AFTER that pick and quietly undo it.
  bool _chosen = false;

  /// Completes once the stored choice has been read back. Exposed so tests (and
  /// any caller that genuinely needs the settled value) can await the hydration
  /// instead of racing it.
  Future<void> get hydrated => _hydrated ?? Future<void>.value();

  @override
  LocalLlmBackend? build() {
    ref.onDispose(() => _disposed = true);
    _hydrated = _restore();
    return null;
  }

  Future<void> _restore() async {
    LocalLlmBackend? stored;
    try {
      stored = await ref.read(localModelBackendPreferenceProvider).forcedBackend();
    } catch (_) {
      // Storage is not a trust boundary and this is a benchmark knob: an
      // unreadable preference (no platform channel in a host test, a broken
      // shared_preferences) means automatic, never a crash on the path that
      // builds the engine for every feature.
      return;
    }
    if (_disposed || _chosen || stored == null || stored == state) return;
    state = stored;
  }

  /// Persists [backend] (`null` = automatic) and makes the next load honour it.
  ///
  /// THE UNLOAD IS THE POINT. `FlutterGemmaLlmEngine.load()` returns early while
  /// `_model != null`, so a model that is already resident would keep running on
  /// the OLD backend no matter what the config says — a benchmark measuring the
  /// backend it thinks it picked. Releasing the handle first means the next load
  /// rebuilds the session on the newly chosen one. Done BEFORE the state change
  /// so it is the engine built from the OLD config that gets released.
  Future<void> setForcedBackend(LocalLlmBackend? backend) async {
    if (backend == state) return;
    _chosen = true;
    await ref.read(localModelBackendPreferenceProvider).setForcedBackend(backend);
    await ref.read(localLlmEngineProvider).dispose();
    if (_disposed) return;
    state = backend;
  }
}
