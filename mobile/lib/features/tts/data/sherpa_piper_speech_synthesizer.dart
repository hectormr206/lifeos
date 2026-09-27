import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_voice.dart';
import 'piper_model_metadata.dart';

/// Piper VITS on-device synthesis. Load, generate and free all happen in a
/// worker isolate; only PCM crosses back to the UI isolate. Raw Piper models
/// are adapted locally before native initialization, without changing weights
/// or the user's selected voice.
class SherpaPiperSpeechSynthesizer implements PiperSpeechSynthesizer {
  const SherpaPiperSpeechSynthesizer();

  @override
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    final SynthesizedAudio audio;
    try {
      audio = await Isolate.run(() => _synthesizeSync(voice, text, speed));
    } on UnsupportedVoiceException {
      rethrow;
    } catch (e) {
      throw PiperSynthesisException('No se pudo sintetizar la voz: $e');
    }
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw PiperSynthesisException('La síntesis de voz no produjo audio.');
    }
    return audio;
  }

  static SynthesizedAudio _synthesizeSync(TtsVoicePaths voice, String text, double speed) {
    final configPath = voice.config;
    if (configPath == null ||
        !File(voice.tokens).existsSync() ||
        !File('${voice.dataDir}/phontab').existsSync()) {
      throw UnsupportedVoiceException('La voz local no está completa.');
    }
    // The paired Piper JSON is mandatory: never guess native metadata from a
    // filename or pass an uninspected model into sherpa (which calls exit(-1)).
    final String configJson;
    try {
      configJson = File(configPath).readAsStringSync();
    } on FileSystemException {
      throw UnsupportedVoiceException('La configuración de la voz no se pudo leer.');
    }
    final modelPath = preparePiperModel(voice.model, configJson);
    sherpa.initBindings();
    final tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath,
            tokens: voice.tokens,
            dataDir: voice.dataDir,
          ),
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    try {
      final safeSpeed = speed.isFinite && speed > 0 ? speed : 1.0;
      final audio = tts.generate(text: text, sid: 0, speed: safeSpeed);
      return SynthesizedAudio(samples: audio.samples, sampleRate: audio.sampleRate);
    } finally {
      tts.free();
    }
  }
}
