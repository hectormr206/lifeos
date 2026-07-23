import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/flutter_gemma_llm_engine.dart';
import '../data/permission_handler_notification_gateway.dart';
import '../data/vps_brain_model_gateway.dart';
import '../domain/brain_model_update_gateway.dart';
import '../domain/brain_model_version_store.dart';
import '../domain/local_llm_engine.dart';
import '../domain/local_model_preferences.dart';
import '../domain/notification_permission.dart';

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
