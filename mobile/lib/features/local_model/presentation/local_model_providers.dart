import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/flutter_gemma_llm_engine.dart';
import '../data/permission_handler_notification_gateway.dart';
import '../data/vps_brain_model_gateway.dart';
import '../domain/brain_model_update_gateway.dart';
import '../domain/brain_model_version_store.dart';
import '../domain/idle_unload_llm_engine.dart';
import '../domain/llm_request_queue.dart';
import '../domain/local_llm_engine.dart';
import '../domain/local_model_backend_preference.dart';
import '../domain/local_model_preferences.dart';
import '../domain/notification_permission.dart';
import '../domain/serial_llm_engine.dart';
import 'local_model_backend_notifier.dart';

/// Persistence for the developer "forzar backend" choice (shared_preferences).
/// Overridden with a fake in tests.
final localModelBackendPreferenceProvider = Provider<LocalModelBackendPreference>(
  (ref) => SharedPrefsLocalModelBackendPreference(),
);

/// The forced inference backend, or `null` for automatic. See
/// [ForcedLocalModelBackendNotifier].
final forcedLocalModelBackendProvider =
    NotifierProvider<ForcedLocalModelBackendNotifier, LocalLlmBackend?>(
  ForcedLocalModelBackendNotifier.new,
);

/// Immutable config for the on-device model (model URL + backend). Overridable
/// in tests / to try the Pixel Tensor-G5 NPU build.
///
/// THE ONE SEAM for the forced backend: `FlutterGemmaLlmEngine.load()` resolves
/// `backend ?? _config.backend`, and every one of the ~11 call sites calls
/// `load()` with no argument — so putting the choice here reaches all of them
/// without touching any. Watching the notifier also means a change rebuilds
/// [localLlmEngineProvider], whose `onDispose` releases the previous engine.
final localModelConfigProvider = Provider<LocalModelConfig>((ref) {
  final forced = ref.watch(forcedLocalModelBackendProvider);
  return forced == null ? const LocalModelConfig() : LocalModelConfig(backend: forced);
});

/// The ONE FIFO queue every piece of on-device model work goes through.
///
/// The phone has a single native inference session; chat, briefing translation,
/// the short-brief writer and the two on-demand summaries all share it. This
/// queue is what makes a second request WAIT instead of cutting the first one
/// short. Kept as its own provider (not private to the engine) so a caller can
/// submit a composite job — e.g. "fetch the page AND summarize it" — as one
/// slot and show the reader whether it is running or still waiting.
final llmRequestQueueProvider = Provider<LlmRequestQueue>((ref) => LlmRequestQueue());

/// The single, long-lived on-device engine (roadmap SLICE 1, model lifecycle):
/// plain (non-autoDispose) Provider so the ENGINE is not rebuilt per screen.
/// Disposed with the ProviderContainer via [Ref.onDispose]. Overridden with a
/// `FakeLocalLlmEngine` in tests.
///
/// Two decorators, in this order — the order is the design:
///
///   IdleUnloadLlmEngine( SerialLlmEngine( FlutterGemmaLlmEngine ) )
///
///   * [SerialLlmEngine] (inner) — serialization belongs at the engine, because
///     every feature holds this same instance and a queue in one of them would
///     leave the rest racing.
///   * [IdleUnloadLlmEngine] (outer) — gives the RAM back once the model has
///     been idle a while, so a background generation on the desktop does not
///     leave ~2.6GB resident for the rest of the session the way it used to.
///     It is OUTSIDE the queue on purpose: its release is submitted as one more
///     queued operation, so it can never free the native handle underneath a
///     running generation.
final localLlmEngineProvider = Provider<LocalLlmEngine>((ref) {
  // No `initializer` override → uses the production default, which registers
  // the real `.litertlm` inference engine (LiteRtLmEngine) with flutter_gemma
  // once before the first model load. Tests override this provider with a fake.
  final engine = IdleUnloadLlmEngine(
    SerialLlmEngine(
      FlutterGemmaLlmEngine(ref.watch(localModelConfigProvider)),
      ref.watch(llmRequestQueueProvider),
    ),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Notification-permission gateway (Android 13+ POST_NOTIFICATIONS) used before
/// a model download so `background_downloader` can post its progress
/// notification. Overridden with a fake in tests.
final notificationPermissionGatewayProvider = Provider<NotificationPermissionGateway>(
  (ref) => const PermissionHandlerNotificationGateway(),
);

/// Local-only toggle persistence (shared_preferences). Overridden with a fake
/// in tests.
final localModelPreferencesProvider =
    Provider<LocalModelPreferences>((ref) => SharedPrefsLocalModelPreferences());

/// The self-hosted brain-model OTA source (VPS manifest + weights). Built from
/// the compile-time config (`--dart-define=BRAIN_MODEL_BASE_URL` overrides,
/// else the placeholder). Overridden with a fake in tests.
final brainModelUpdateGatewayProvider = Provider<BrainModelUpdateGateway>(
  (ref) => VpsBrainModelGateway(),
);

/// Tracked installed brain-model identity (shared_preferences) — what the
/// server manifest's versionCode is compared against. Overridden with a fake
/// in tests.
final brainModelVersionStoreProvider =
    Provider<BrainModelVersionStore>((ref) => SharedPrefsBrainModelVersionStore());

/// Whether the app is in on-device (local model) chat mode.
///
/// LifeOS is now on-device-first with every required model installable, so
/// local mode is ALWAYS ON — there is no user-facing toggle any more. The
/// provider is kept (rather than inlining `true` at every call site) so the
/// existing consumers keep reading it unchanged: the `/chat` router gate
/// (`localChatAllowed`), `chatRepositoryProvider` (on-device branch), the
/// model-load warmup, and the C1 memory write-back. It simply always reports
/// `true`, so every one of those paths takes the on-device path.
final localModelEnabledProvider =
    NotifierProvider<LocalModelEnabledNotifier, bool>(LocalModelEnabledNotifier.new);

class LocalModelEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;
}
