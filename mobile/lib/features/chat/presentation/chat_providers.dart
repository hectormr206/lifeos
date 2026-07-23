import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audioplayers_audio_player_gateway.dart';
import '../data/flutter_tts_text_to_speech_gateway.dart';
import '../data/image_picker_image_gateway.dart';
import '../../tts/data/audioplayers_tts_playback.dart';
import '../../tts/data/piper_preferred_text_to_speech_gateway.dart';
import '../../tts/data/sherpa_piper_tts_gateway.dart';
import '../../tts/presentation/tts_providers.dart';
import '../../voice_settings/presentation/voice_catalog_providers.dart';
import '../../voice_settings/presentation/voice_settings_providers.dart';
import '../data/record_audio_recorder_gateway.dart';
import '../domain/audio_player_gateway.dart';
import '../domain/audio_recorder_gateway.dart';
import '../domain/image_picker_gateway.dart';
import '../../../l10n/locale_providers.dart';
import '../domain/text_to_speech_gateway.dart';
import '../domain/voice_reply_preferences.dart';

/// Whether "buscar en internet" (web search) is active for the chat (roadmap
/// slice B4). When `true`, `chatRepositoryProvider` wraps the active repository
/// in a `SearchAugmentedChatRepository` so each text turn is grounded in live
/// DuckDuckGo results with a "Fuentes:"/"Sources:" list. Defaults to `false`
/// (off) and lives only in memory — a per-session choice, not persisted.
///
/// EVERYTHING-ON EXCEPTION (deliberate): unlike the other feature toggles that
/// this slice defaults ON, this one STAYS OFF by default. Running a live web
/// search on EVERY chat message is costly + slow (a network round-trip per
/// turn), so it is a per-message opt-in the user flips with the globe button.
/// The provider *selection* is DuckDuckGo-ready out of the box
/// (`WebSearchProvider.duckduckgo` default) — only the per-message execution is
/// opt-in.
///
/// A [NotifierProvider] (not the legacy `StateProvider`, which riverpod 3 keeps
/// only under `flutter_riverpod/legacy`) to match the codebase convention.
final webSearchEnabledProvider =
    NotifierProvider<WebSearchEnabledNotifier, bool>(WebSearchEnabledNotifier.new);

class WebSearchEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Flips the toggle (globe button).
  void toggle() => state = !state;

  /// Sets the toggle to [value].
  void set(bool value) => state = value;
}

/// Photo attach (camera/gallery). Overridden with a fake in tests.
final imagePickerGatewayProvider =
    Provider<ImagePickerGateway>((ref) => ImagePickerImageGateway());

/// Press-and-hold voice-note recorder. Overridden with a fake in tests.
final audioRecorderGatewayProvider =
    Provider<AudioRecorderGateway>((ref) => RecordAudioRecorderGateway());

/// Voice-note playback. Long-lived (one shared player); disposed with the
/// container. Overridden with a fake in tests.
final audioPlayerGatewayProvider = Provider<AudioPlayerGateway>((ref) {
  final gateway = AudioPlayersAudioPlayerGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// "Axi habla" (speak-aloud) engine. Long-lived (one shared engine); disposed
/// with the container. Overridden with a fake in tests.
///
/// Roadmap slice B3 (the SWAP SEAM cashing in): Piper neural voices via
/// sherpa-onnx are now PREFERRED, with the OS voice (`flutter_tts`) as the
/// always-works fallback. When the Piper voice for the current language is
/// not downloaded yet, the first speak triggers its background download and
/// the system voice covers that utterance — Piper takes over next time. No
/// UI or [SpeechController] change: same [TextToSpeechGateway] contract.
final textToSpeechGatewayProvider = Provider<TextToSpeechGateway>((ref) {
  // i18n slice: the spoken voice follows the current app language. `read` at
  // speak-time (not `watch`) so a language change re-selects the voice without
  // recreating (and re-loading) the shared engine.
  String currentLanguageCode() => ref.read(appLanguageCodeProvider);
  // The NEURAL voice follows the user's explicit pick (default es_MX-claude),
  // read live at speak-time so a new pick applies to the next utterance without
  // recreating (and re-loading) the shared engine. The system FALLBACK still
  // follows the app language (it has a voice per locale, not per pick).
  String currentVoiceId() => ref.read(selectedVoiceProvider);
  // Read the "Voz" tuning LIVE at speak-time (not `watch`) so the rate slider
  // applies to the next utterance without recreating the shared engine.
  final gateway = PiperPreferredTextToSpeechGateway(
    preferred: SherpaPiperTtsGateway(
      voiceGateway: ref.watch(ttsVoiceGatewayProvider),
      synthesizer: ref.watch(piperSpeechSynthesizerProvider),
      playback: AudioplayersTtsPlayback(),
      currentVoiceId: currentVoiceId,
      currentSpeed: () => ref.read(voiceSettingsProvider).piperSpeed,
    ),
    fallback: FlutterTtsTextToSpeechGateway(
      currentLanguageCode: currentLanguageCode,
      currentRate: () => ref.read(voiceSettingsProvider).systemRate,
      currentPitch: () => ref.read(voiceSettingsProvider).systemPitch,
    ),
    // Lazy first-speak trigger: fire-and-forget so the fallback utterance is
    // never blocked by the (large) voice download.
    onVoiceAbsent: () => unawaited(
        ref.read(voiceCatalogControllerProvider.notifier).download(ref.read(selectedVoiceProvider))),
  );
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// Which message (by [ChatMessage.id]) is currently being read aloud, or `null`
/// when nothing is speaking. Drives the per-bubble speak ↔ stop toggle and
/// guarantees only ONE message speaks at a time.
final speechControllerProvider =
    NotifierProvider<SpeechController, String?>(SpeechController.new);

class SpeechController extends Notifier<String?> {
  StreamSubscription<void>? _sub;

  @override
  String? build() {
    final gateway = ref.watch(textToSpeechGatewayProvider);
    // When an utterance ends on its own, revert the active button to "speak".
    _sub = gateway.completions.listen((_) => state = null);
    ref.onDispose(() => _sub?.cancel());
    return null;
  }

  /// Speaks [text] for message [id]. If that message is already speaking, this
  /// stops it (tap-to-toggle). Starting a new message stops the previous one —
  /// only one plays at a time.
  Future<void> toggle(String id, String text) async {
    final gateway = ref.read(textToSpeechGatewayProvider);
    if (state == id) {
      state = null;
      await gateway.stop();
      return;
    }
    state = id;
    await gateway.speak(text);
  }

  /// Stops any active speech (e.g. when leaving the chat screen). Safe to call
  /// when nothing is playing.
  Future<void> stop() async {
    if (state == null) return;
    state = null;
    await ref.read(textToSpeechGatewayProvider).stop();
  }
}

/// "Responder por voz" preference persistence. Overridden with a fake in tests.
final voiceReplyPreferencesProvider =
    Provider<VoiceReplyPreferences>((ref) => SharedPrefsVoiceReplyPreferences());

/// The persisted "Responder por voz" (Axi auto-speaks new replies) toggle
/// value. When `true`, the chat screen speaks every newly-arrived Axi text
/// reply aloud via the shared [SpeechController]. The EFFECTIVE default is ON
/// (the "everything-on" rule): the persisted preference defaults to `true`
/// ([SharedPrefsVoiceReplyPreferences.isEnabled] → `?? true`), so a fresh
/// install speaks out of the box and the user opts out. The notifier starts at
/// the safe pre-hydration value `false` and flips to the persisted `true`
/// within the first frame — deliberately NOT `true` here, so a chat opened with
/// a single historical reply is never mistaken for a fresh append and spoken on
/// load (the `_maybeSpeakNewReply` +1-append heuristic).
final voiceReplyEnabledProvider =
    NotifierProvider<VoiceReplyEnabledNotifier, bool>(VoiceReplyEnabledNotifier.new);

class VoiceReplyEnabledNotifier extends Notifier<bool> {
  Future<void>? _hydration;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  bool build() {
    _hydration = _hydrate();
    return false;
  }

  Future<void> _hydrate() async {
    try {
      state = await ref.read(voiceReplyPreferencesProvider).isEnabled();
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // stay at the safe default rather than crashing.
    }
  }

  /// Flips the toggle and persists it.
  Future<void> setEnabled(bool value) async {
    state = value;
    try {
      await ref.read(voiceReplyPreferencesProvider).setEnabled(value);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
  }
}
