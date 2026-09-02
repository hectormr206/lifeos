import 'package:shared_preferences/shared_preferences.dart';

import 'local_llm_engine.dart';

/// Local-only persistence for the DEVELOPER "force the inference backend"
/// choice (a benchmark affordance, not a product feature).
///
/// WHY IT EXISTS. Every call site asks for `engine.load()` with no argument, so
/// the app always requests [LocalLlmBackend.gpu] and the `backend` recorded in
/// GenerationMetrics only ever reads "cpu" when a load FAILED and fell back.
/// That leaves no CPU cohort to compare a GPU run against. Forcing the backend
/// from a stored preference gives the benchmark its second arm.
///
/// AUTOMATIC IS ABSENCE. "Automatic" (today's GPU-first behaviour with its
/// CPU fallback) is `null` — the key is REMOVED, never written as a magic
/// string. That keeps a fresh install, a cleared preference and an explicit
/// "automático" indistinguishable, which is what they are.
///
/// Storage is not a trust boundary: an unknown stored value reads back as
/// automatic rather than throwing.
abstract class LocalModelBackendPreference {
  /// The forced backend, or `null` for automatic (never set, or cleared).
  Future<LocalLlmBackend?> forcedBackend();

  /// Persists the forced backend; `null` clears the choice (automatic).
  Future<void> setForcedBackend(LocalLlmBackend? backend);
}

/// [LocalModelBackendPreference] backed by `shared_preferences`. Ordinary
/// preference, not a secret — same tier as `local_model_enabled`.
class SharedPrefsLocalModelBackendPreference implements LocalModelBackendPreference {
  SharedPrefsLocalModelBackendPreference({this._prefs});

  static const String forcedBackendKey = 'local_model_forced_backend';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<LocalLlmBackend?> forcedBackend() async {
    final stored = (await _instance).getString(forcedBackendKey);
    if (stored == null) return null;
    for (final backend in LocalLlmBackend.values) {
      if (backend.name == stored) return backend;
    }
    // Unknown value (a downgrade, a hand-edited prefs file): automatic.
    return null;
  }

  @override
  Future<void> setForcedBackend(LocalLlmBackend? backend) async {
    final prefs = await _instance;
    if (backend == null) {
      await prefs.remove(forcedBackendKey);
      return;
    }
    await prefs.setString(forcedBackendKey, backend.name);
  }
}
