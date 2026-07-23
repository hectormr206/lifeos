import 'dart:async';

import '../../chat/domain/text_to_speech_gateway.dart';
import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_playback.dart';
import '../domain/tts_voice_gateway.dart';
import 'wav_encoder.dart';

/// [TextToSpeechGateway] backed by the on-device Piper neural voice via
/// sherpa-onnx (roadmap slice B3) — the engine that replaces the robotic OS
/// voice.
///
/// speak(): resolve the installed voice for the CURRENT app language →
/// synthesize OFF the UI thread → wrap the Float32 PCM in a WAV header →
/// play from memory. Natural playback end surfaces on [completions].
///
/// It does NOT fall back by itself — when the voice is not installed it
/// throws [PiperVoiceUnavailableException] and on engine failure
/// [PiperSynthesisException], so the composite
/// [PiperPreferredTextToSpeechGateway] can route to the system voice (and
/// trigger the lazy download) while keeping this class single-purpose.
class SherpaPiperTtsGateway implements TextToSpeechGateway {
  SherpaPiperTtsGateway({
    required this._voiceGateway,
    required this._synthesizer,
    required this._playback,
    required this._currentLanguageCode,
    double Function()? currentSpeed,
  }) : _currentSpeed = currentSpeed ?? _defaultSpeed;

  static double _defaultSpeed() => 1.0;

  final TtsVoiceGateway _voiceGateway;
  final PiperSpeechSynthesizer _synthesizer;
  final TtsPlayback _playback;

  /// Reads the CURRENT app language live at each speak, so switching language
  /// in Settings changes the spoken voice without recreating the gateway.
  final String Function() _currentLanguageCode;

  /// Reads the CURRENT speech-rate multiplier live at each speak, so the "Voz"
  /// slider applies to the next utterance without recreating the gateway.
  final double Function() _currentSpeed;

  /// Bumped by every speak/stop; a synthesis whose epoch is stale by the time
  /// it finishes is discarded instead of played (stop() cancels pending synth).
  int _epoch = 0;

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    // Claim the epoch BEFORE the first await so a stop() racing even the
    // voice probe already cancels this utterance.
    final epoch = ++_epoch;
    final languageCode = _currentLanguageCode();
    final voice = await _voiceGateway.installedVoice(languageCode);
    if (voice == null) throw PiperVoiceUnavailableException(languageCode);
    if (epoch != _epoch) return; // stopped / superseded during the probe

    await _playback.stop(); // one utterance at a time
    final audio =
        await _synthesizer.synthesize(voice: voice, text: text, speed: _currentSpeed());
    if (epoch != _epoch) return; // stopped / superseded while synthesizing
    await _playback.play(pcmFloat32ToWav16(audio.samples, audio.sampleRate));
  }

  @override
  Future<void> stop() async {
    _epoch++; // discard any in-flight synthesis result
    await _playback.stop();
  }

  @override
  Stream<void> get completions => _playback.completions;

  @override
  Future<void> dispose() async {
    _epoch++;
    await _playback.dispose();
  }
}
