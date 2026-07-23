import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_playback.dart';
import '../domain/tts_voice.dart';
import 'wav_encoder.dart';

/// Plays a short sample sentence with ONE specific installed voice so the user
/// can "Preescuchar" it before selecting.
///
/// It reuses the exact same synthesize → WAV → play chain the main speak path
/// uses ([PiperSpeechSynthesizer] + [TtsPlayback]) — no engine logic is
/// duplicated. It never resolves or downloads the voice itself: the caller
/// passes already-resolved [TtsVoicePaths], keeping this class single-purpose
/// and trivially fakeable in tests.
class TtsPreview {
  TtsPreview({required PiperSpeechSynthesizer synthesizer, required TtsPlayback playback})
      : _synthesizer = synthesizer,
        _playback = playback;

  final PiperSpeechSynthesizer _synthesizer;
  final TtsPlayback _playback;

  /// Synthesizes [text] with [voice] and plays it, stopping any previous
  /// preview first (one sample at a time).
  Future<void> play({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    if (text.trim().isEmpty) return;
    final audio = await _synthesizer.synthesize(voice: voice, text: text, speed: speed);
    await _playback.stop();
    await _playback.play(pcmFloat32ToWav16(audio.samples, audio.sampleRate));
  }

  Future<void> stop() => _playback.stop();

  Future<void> dispose() => _playback.dispose();
}
