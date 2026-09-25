// ZIPA, the phone recogniser, over one WAV: the native part of pronunciation
// feedback as one synchronous function.
//
// It imports nothing but sherpa-onnx, so it can be run for real outside the
// app (`dart run`, with an explicit library path), which is how it was
// measured; the app runs it in a worker isolate (pronunciation_coach.dart).
library;

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Runs ZIPA over a 16 kHz (or any rate; sherpa resamples) WAV.
String recognizePhones({
  required String wavPath,
  required String model,
  required String tokens,
  String? bindingsPath,
}) {
  sherpa.initBindings(bindingsPath);
  final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      zipformerCtc: sherpa.OfflineZipformerCtcModelConfig(model: model),
      tokens: tokens,
      numThreads: 2,
      debug: false,
    ),
  ));
  final stream = recognizer.createStream();
  try {
    final wave = sherpa.readWave(wavPath);
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    return recognizer.getResult(stream).text;
  } finally {
    stream.free();
    recognizer.free();
  }
}

