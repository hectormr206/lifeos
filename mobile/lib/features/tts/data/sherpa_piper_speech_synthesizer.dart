import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_voice.dart';
import 'piper_tokens.dart';

/// [PiperSpeechSynthesizer] backed by the offline sherpa-onnx VITS engine
/// running a Piper voice (roadmap slice B3). Fully on-device.
///
/// Threading: `OfflineTts.generate` is CPU-bound FFI (hundreds of ms for a
/// paragraph), so the WHOLE load→generate→free cycle runs inside
/// [Isolate.run] — it never touches the UI thread. Only the Float32 samples
/// travel back.
///
/// RAM discipline (same trade as [SherpaSttService]): the engine is loaded
/// per synthesis and freed immediately after, so a ~60 MB VITS never lingers
/// next to the on-device LLM. Loading a VITS is fast, and speak-aloud is an
/// occasional, user-triggered action.
class SherpaPiperSpeechSynthesizer implements PiperSpeechSynthesizer {
  const SherpaPiperSpeechSynthesizer();

  @override
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    // Reject an incompatible voice BEFORE touching sherpa: an unsupported
    // config (non-espeak phoneme_type or multi-speaker) crashes the engine
    // NATIVELY — uncatchable — so we throw a catchable [UnsupportedVoiceException]
    // here instead. Runs OUTSIDE the try/catch below so it is NOT rewrapped as
    // a generic synthesis failure and stays catchable by the call sites.
    await _assertVoiceCompatible(voice);

    final SynthesizedAudio audio;
    try {
      audio = await Isolate.run(() => _synthesizeSync(voice, text, speed));
    } catch (e) {
      throw PiperSynthesisException('No se pudo sintetizar la voz: $e');
    }
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      // sherpa-onnx signals engine failure with empty audio, not an exception.
      throw PiperSynthesisException('La síntesis de voz no produjo audio.');
    }
    return audio;
  }

  /// Parses the voice's `*.onnx.json` and throws [UnsupportedVoiceException]
  /// when it is incompatible with the engine (see [assertPiperVoiceCompatible]).
  /// Skips silently when no config path is supplied (test fakes) or the file is
  /// unreadable — we only ever REFUSE a config we can positively see is unsafe,
  /// never block a voice we cannot inspect.
  static Future<void> _assertVoiceCompatible(TtsVoicePaths voice) async {
    final configPath = voice.config;
    if (configPath == null) return;
    final String json;
    try {
      json = await File(configPath).readAsString();
    } catch (_) {
      return; // cannot read → cannot judge; let synthesis proceed/fail normally
    }
    assertPiperVoiceCompatible(json); // throws UnsupportedVoiceException if unsafe
  }

  /// Runs in the worker isolate — sherpa's FFI bindings are per-isolate, so
  /// init here (cheap + idempotent) before building the engine.
  static SynthesizedAudio _synthesizeSync(TtsVoicePaths voice, String text, double speed) {
    sherpa.initBindings();
    final tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: voice.model,
            tokens: voice.tokens,
            // Piper phonemization needs the extracted espeak-ng-data DIRECTORY.
            dataDir: voice.dataDir,
          ),
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    try {
      // Guard the FFI call against a bogus multiplier reaching the engine.
      final safeSpeed = speed.isFinite && speed > 0 ? speed : 1.0;
      final audio = tts.generate(text: text, sid: 0, speed: safeSpeed);
      return SynthesizedAudio(samples: audio.samples, sampleRate: audio.sampleRate);
    } finally {
      tts.free();
    }
  }
}
