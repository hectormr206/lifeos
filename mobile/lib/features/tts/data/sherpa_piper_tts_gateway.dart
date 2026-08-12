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
/// Synthesis returned no samples at all. File-private: it exists only to keep
/// "silence" distinguishable from "crash" between [_speakOrThrow] and the
/// classifier a few lines below, and the composite catches everything anyway.
class _EmptyAudioException implements Exception {
  _EmptyAudioException(this.voiceId);
  final String voiceId;
  @override
  String toString() => 'Piper voice "$voiceId" produced no audio.';
}

/// The audio existed and the player refused it — a failure DOWNSTREAM of the
/// voice, so replacing the voice would not help. File-private for the same
/// reason as [_EmptyAudioException].
class _PlaybackException implements Exception {
  _PlaybackException(this.cause);
  final Object cause;
  @override
  String toString() => 'Playback of the synthesized audio failed: $cause';
}

class SherpaPiperTtsGateway implements TextToSpeechGateway {
  SherpaPiperTtsGateway({
    required this._voiceGateway,
    required this._synthesizer,
    required this._playback,
    required this._currentVoiceId,
    double Function()? currentSpeed,
  }) : _currentSpeed = currentSpeed ?? _defaultSpeed;

  static double _defaultSpeed() => 1.0;

  final TtsVoiceGateway _voiceGateway;
  final PiperSpeechSynthesizer _synthesizer;
  final TtsPlayback _playback;

  /// Reads the CURRENT selected voice id live at each speak, so picking a voice
  /// in Settings → Voz changes the spoken voice without recreating the gateway.
  final String Function() _currentVoiceId;

  /// Reads the CURRENT speech-rate multiplier live at each speak, so the "Voz"
  /// slider applies to the next utterance without recreating the gateway.
  final double Function() _currentSpeed;

  /// Bumped by every speak/stop; a synthesis whose epoch is stale by the time
  /// it finishes is discarded instead of played (stop() cancels pending synth).
  int _epoch = 0;

  @override
  Future<void> speak(String text) => _speakOrThrow(text);

  /// Classifies THIS engine's own failures. The composite above uses it to
  /// decide between "the neural voice spoke" and "we fell back, and here is
  /// why" — so every distinction has to be made here, where the step that
  /// failed is still known.
  @override
  Future<VoiceTestOutcome> speakDiagnostic(String text) async {
    try {
      await _speakOrThrow(text);
      return const VoiceTestSpoke(VoiceTestEngine.neural);
    } on PiperVoiceUnavailableException catch (e) {
      return VoiceTestFailed(VoiceTestFailure.voiceMissing, detail: '$e');
    } on UnsupportedVoiceException catch (e) {
      return VoiceTestFailed(VoiceTestFailure.voiceIncompatible, detail: '$e');
    } on _EmptyAudioException catch (e) {
      return VoiceTestFailed(VoiceTestFailure.emptySynthesis, detail: '$e');
    } on _PlaybackException catch (e) {
      return VoiceTestFailed(VoiceTestFailure.playbackFailed, detail: '${e.cause}');
    } on PiperSynthesisException catch (e) {
      return VoiceTestFailed(VoiceTestFailure.synthesisFailed, detail: '$e');
    } catch (e) {
      // Not attributable to a step above. Reported as such rather than blamed
      // on the most likely suspect.
      return VoiceTestFailed(VoiceTestFailure.unknown, detail: '$e');
    }
  }

  Future<void> _speakOrThrow(String text) async {
    if (text.trim().isEmpty) return;
    // Claim the epoch BEFORE the first await so a stop() racing even the
    // voice probe already cancels this utterance.
    final epoch = ++_epoch;
    final voiceId = _currentVoiceId();
    final voice = await _voiceGateway.installedVoice(voiceId);
    if (voice == null) throw PiperVoiceUnavailableException(voiceId);
    if (epoch != _epoch) return; // stopped / superseded during the probe

    await _playback.stop(); // one utterance at a time
    final audio =
        await _synthesizer.synthesize(voice: voice, text: text, speed: _currentSpeed());
    if (epoch != _epoch) return; // stopped / superseded while synthesizing
    // "It ran and produced silence" is a DIFFERENT observation from "it blew
    // up", and playing an empty buffer would report success for a test the
    // user cannot hear.
    if (audio.samples.isEmpty) throw _EmptyAudioException(voiceId);
    try {
      await _playback.play(pcmFloat32ToWav16(audio.samples, audio.sampleRate));
    } catch (e) {
      throw _PlaybackException(e);
    }
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
