import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audioplayers_audio_player_gateway.dart';
import '../data/image_picker_image_gateway.dart';
import '../data/record_audio_recorder_gateway.dart';
import '../domain/audio_player_gateway.dart';
import '../domain/audio_recorder_gateway.dart';
import '../domain/image_picker_gateway.dart';
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
