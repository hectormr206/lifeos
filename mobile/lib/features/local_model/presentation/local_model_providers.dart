import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/flutter_gemma_llm_engine.dart';
import '../domain/local_llm_engine.dart';
import '../domain/local_model_preferences.dart';

/// Immutable config for the on-device model (model URL + backend). Overridable
/// in tests / to try the Pixel Tensor-G5 NPU build.
final localModelConfigProvider = Provider<LocalModelConfig>((ref) => const LocalModelConfig());

/// The single, long-lived on-device engine (roadmap SLICE 1, model lifecycle):
/// plain (non-autoDispose) Provider so the loaded weights are NOT reloaded per
/// screen. Disposed with the ProviderContainer via [Ref.onDispose].
/// Overridden with a `FakeLocalLlmEngine` in tests.
final localLlmEngineProvider = Provider<LocalLlmEngine>((ref) {
  // No `initializer` override → uses the production default, which registers
  // the real `.litertlm` inference engine (LiteRtLmEngine) with flutter_gemma
  // once before the first model load. Tests override this provider with a fake.
  final engine = FlutterGemmaLlmEngine(ref.watch(localModelConfigProvider));
  ref.onDispose(engine.dispose);
  return engine;
});

/// Local-only toggle persistence (shared_preferences). Overridden with a fake
/// in tests.
final localModelPreferencesProvider =
    Provider<LocalModelPreferences>((ref) => SharedPrefsLocalModelPreferences());

/// Whether the app is in on-device (local model) chat mode.
///
/// Exposes a synchronous [bool] (default `false`) so `chatRepositoryProvider`
/// and the router `redirect` can read it without awaiting; the persisted value
/// is loaded asynchronously in [LocalModelEnabledNotifier.build] and flips the
/// state once known.
final localModelEnabledProvider =
    NotifierProvider<LocalModelEnabledNotifier, bool>(LocalModelEnabledNotifier.new);

class LocalModelEnabledNotifier extends Notifier<bool> {
  /// Set once the user explicitly toggles, so a late-resolving hydration read
  /// (kicked off in [build]) never clobbers a deliberate choice — the classic
  /// async-load vs. write race.
  bool _userSet = false;

  @override
  bool build() {
    // Default OFF; hydrate from persistence without blocking first read.
    unawaitedLoad();
    return false;
  }

  Future<void> unawaitedLoad() async {
    try {
      final persisted = await ref.read(localModelPreferencesProvider).isEnabled();
      if (!_userSet) state = persisted;
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // stay at the safe default rather than crashing app startup.
    }
  }

  /// Flips the toggle and persists it.
  Future<void> setEnabled(bool value) async {
    _userSet = true;
    state = value;
    try {
      await ref.read(localModelPreferencesProvider).setEnabled(value);
    } catch (_) {
      // Best-effort persistence; the in-memory state still reflects the choice.
    }
  }
}
