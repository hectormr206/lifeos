import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/speech_to_text.dart';
import '../domain/stt_model_gateway.dart';

/// [SpeechToText] backed by the offline sherpa-onnx Whisper recognizer
/// (roadmap slice B2). Fully on-device: no network, no server.
///
/// RAM discipline: the recognizer is lazy-loaded on the FIRST call and DISPOSED
/// (`free()`) as soon as the transcription completes — it is never kept hot
/// alongside the on-device LLM (which owns most of the VRAM/RAM budget). Every
/// transcription therefore pays a one-off load, which is the right trade for a
/// short, occasional voice note versus holding ~80 MB of weights resident.
class SherpaSttService implements SpeechToText {
  SherpaSttService(this._modelGateway);

  final SttModelGateway _modelGateway;

  /// sherpa-onnx's FFI bindings must be initialised once before any runtime
  /// object is built; guarded so repeated transcriptions init only once.
  static bool _bindingsReady = false;

  @override
  Future<String> transcribe(String wavPath, {required String languageCode}) async {
    final model = await _modelGateway.installedModel();
    if (model == null) {
      throw SttException('El modelo de voz no está descargado todavía.');
    }

    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }

    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: model.encoder,
          decoder: model.decoder,
          language: sttWhisperLanguage(languageCode),
          task: 'transcribe',
        ),
        tokens: model.tokens,
        modelType: 'whisper',
        numThreads: 2,
        debug: false,
      ),
    );

    // Lazy-load the recognizer; ALWAYS free it (and the stream) afterwards so
    // it never lingers next to the LLM.
    sherpa.OfflineRecognizer? recognizer;
    sherpa.OfflineStream? stream;
    try {
      recognizer = sherpa.OfflineRecognizer(config);
      final wave = sherpa.readWave(wavPath);
      stream = recognizer.createStream();
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } catch (e) {
      throw SttException('No se pudo transcribir la nota de voz: $e');
    } finally {
      stream?.free();
      recognizer?.free();
    }
  }
}
