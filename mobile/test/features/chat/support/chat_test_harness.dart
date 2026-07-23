// Shared chat-screen test harness.
//
// Local mode is always on now (on-device-first), so every chat render mounts
// the readiness gate plus the model-load and STT banners. This harness pins
// those on-device-only providers to ready/quiet via a nested ProviderScope
// baked into [chatApp], so a test that only cares about the composer and
// message bubbles renders them without touching a real engine/download channel.
// A test's own outer overrides (chat repository, TTS, prefs, web-search, mic
// gateways) are inherited unchanged — the baseline only sets providers no such
// test varies, so there is never a duplicate override.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import 'package:lifeos/features/local_model/presentation/local_model_load_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/required_models.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

/// Pins the on-device model-load state to READY (no engine warm-up), so the
/// composer renders and send is never gated in tests that don't target the
/// load banner.
class ReadyLoadNotifier extends LocalModelLoadNotifier {
  @override
  LocalModelLoadState build() => const LocalModelLoadState(status: LocalModelLoadStatus.ready);
}

/// Pins the STT download notifier to a fixed status without the async hydration
/// probe.
class FixedSttStatusNotifier extends SttModelDownloadNotifier {
  FixedSttStatusNotifier(this._fixed);

  final SttModelStatus _fixed;

  @override
  SttModelStatus build() => _fixed;
}

/// The chat screen in a Spanish-localized MaterialApp with the on-device-safe
/// baseline (see file header) applied via a nested ProviderScope. Wrap it in an
/// outer ProviderScope carrying the test's own overrides.
final Widget chatApp = MaterialApp(
  home: ProviderScope(
    overrides: [
      lifeOsModelsReadyProvider.overrideWithValue(true),
      localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
      localModelLoadProvider.overrideWith(ReadyLoadNotifier.new),
      sttModelDownloadProvider.overrideWith(() => FixedSttStatusNotifier(const SttModelReady())),
    ],
    child: const ChatScreen(),
  ),
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
);
