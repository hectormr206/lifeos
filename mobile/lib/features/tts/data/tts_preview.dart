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
      : this._(synthesizer, playback);

  TtsPreview._(this._synthesizer, this._playback);

  final PiperSpeechSynthesizer _synthesizer;
  final TtsPlayback _playback;

  /// Monotonic request counter (same pattern as the main speak path's `_epoch`
  /// in `sherpa_piper_tts_gateway.dart`): each [play] takes a ticket, and any
  /// await-point re-check discards a STALE request. Without it, a slow first
  /// preview finishing late would stop and replace the voice the user tapped
  /// LAST — they would hear the wrong voice for the row they chose.
  int _epoch = 0;

  /// Synthesizes [text] with [voice] and plays it, stopping any previous
  /// preview first (one sample at a time). Only the MOST RECENTLY requested
  /// preview ever reaches the speaker; a late-finishing older one is dropped.
  Future<void> play({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    if (text.trim().isEmpty) return;
    final ticket = ++_epoch;
    final audio = await _synthesizer.synthesize(voice: voice, text: text, speed: speed);
    // A newer preview (or stop) was requested while synthesizing → this result
    // is stale; do NOT cut off the newest playback to play an old sample.
    if (ticket != _epoch) return;
    await _playback.stop();
    if (ticket != _epoch) return;
    await _playback.play(pcmFloat32ToWav16(audio.samples, audio.sampleRate));
  }

  Future<void> stop() {
    _epoch++; // invalidate any in-flight synthesis so it can't play late.
    return _playback.stop();
  }

  Future<void> dispose() {
    _epoch++;
    return _playback.dispose();
  }
}
