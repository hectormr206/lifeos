import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audioplayers_audio_player_gateway.dart';
import '../data/flutter_tts_text_to_speech_gateway.dart';
import '../data/image_picker_image_gateway.dart';
import '../data/record_audio_recorder_gateway.dart';
import '../domain/audio_player_gateway.dart';
import '../domain/audio_recorder_gateway.dart';
import '../domain/image_picker_gateway.dart';
import '../../../l10n/locale_providers.dart';
import '../domain/text_to_speech_gateway.dart';
import '../domain/voice_reply_preferences.dart';

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
/// SWAP SEAM: point this at a higher-quality on-device engine (Piper) behind
/// [TextToSpeechGateway] later — no UI or controller change needed.
final textToSpeechGatewayProvider = Provider<TextToSpeechGateway>((ref) {
  // i18n slice: the spoken voice follows the current app language. `read` at
  // speak-time (not `watch`) so a language change re-selects the voice without
  // recreating (and re-loading) the shared engine.
  final gateway = FlutterTtsTextToSpeechGateway(
    currentLanguageCode: () => ref.read(appLanguageCodeProvider),
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

/// The persisted "Responder por voz" (Axi speaks) toggle value.
///
/// The feature is DISABLED in the UI until the on-device TTS model lands, but
/// the user's chosen preference is hydrated + persisted here so it is ready
/// the moment TTS ships. Defaults to `false`; hydrates asynchronously without
/// blocking first read.
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
