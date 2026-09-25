// Voice activity detection plus Whisper over a long recording, on the device.
//
// Silero VAD (bundled, 213 KB) cuts the voice out of the audio; neighbouring
// cuts are joined into Whisper-sized chunks (domain/speech_segments.dart);
// Whisper base, the same model the app already uses for voice notes, reads
// each chunk as English. The recognizer is loaded ONCE for the whole file.
//
// It runs in a worker isolate: these are synchronous FFI calls that take
// minutes on a long file, and the UI thread must never wait on them. The
// worker reports progress after every chunk.
//
// [transcribeLongWav] is the whole job as one function so that it can be run
// for real outside the app (with an explicit path to the native library),
// which is how it was measured: 13.4 minutes of LibriVox audio, 61 chunks,
// about a third of real time on the devbox.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../stt/domain/stt_model.dart';
import '../../stt/domain/stt_model_gateway.dart';
import '../domain/speech_segments.dart';
import 'audio_importer.dart';

const int _sampleRate = 16000;
const int _vadWindow = 512;

/// Runs the whole transcription synchronously. [bindingsPath] points at the
/// native sherpa-onnx library when running outside a Flutter app.
List<String> transcribeLongWav({
  required String wavPath,
  required String vadModel,
  required SttModelPaths whisper,
  required int maxSeconds,
  required void Function(int done, int total) onProgress,
  String? bindingsPath,
}) {
  sherpa.initBindings(bindingsPath);
  final wave = sherpa.readWave(wavPath);
  if (wave.sampleRate != _sampleRate) {
    throw StateError('Expected 16 kHz audio, got ${wave.sampleRate} Hz');
  }
  final limit = maxSeconds * _sampleRate;
  final samples = wave.samples.length > limit
      ? Float32List.sublistView(wave.samples, 0, limit)
      : wave.samples;

  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadModel,
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        windowSize: _vadWindow,
        maxSpeechDuration: kMaxChunkSeconds,
      ),
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  final segments = <SpeechSpan>[];
  void drain() {
    while (!vad.isEmpty()) {
      final s = vad.front();
      segments.add(SpeechSpan(start: s.start, length: s.samples.length));
      vad.pop();
    }
  }

  try {
    for (var i = 0; i + _vadWindow <= samples.length; i += _vadWindow) {
      vad.acceptWaveform(Float32List.sublistView(samples, i, i + _vadWindow));
      drain();
    }
    vad.flush();
    drain();
  } finally {
    vad.free();
  }

  final chunks = joinSegments(segments, sampleRate: _sampleRate);
  if (chunks.isEmpty) return const [];

  final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: whisper.encoder,
        decoder: whisper.decoder,
        language: 'en',
        task: 'transcribe',
      ),
      tokens: whisper.tokens,
      modelType: 'whisper',
      numThreads: 2,
      debug: false,
    ),
  ));
  final texts = <String>[];
  try {
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.sublistView(
              samples, c.start, c.end.clamp(0, samples.length)),
          sampleRate: _sampleRate,
        );
        recognizer.decode(stream);
        texts.add(recognizer.getResult(stream).text.trim());
      } finally {
        stream.free();
      }
      onProgress(i + 1, chunks.length);
    }
  } finally {
    recognizer.free();
  }
  return texts;
}

class SherpaLongAudioRecognizer implements LongAudioRecognizer {
  SherpaLongAudioRecognizer(this._models, this._vadModel);

  final SttModelGateway _models;

  /// Path of the Silero VAD model on disk (it ships as an asset).
  final Future<String> Function() _vadModel;

  @override
  Stream<TranscriptionEvent> transcribe(
    String wavPath, {
    required int maxSeconds,
  }) async* {
    final whisper = await _models.installedModel();
    if (whisper == null) throw const SpeechModelMissing();
    final vad = await _vadModel();

    final port = ReceivePort();
    final isolate = await Isolate.spawn(
      _work,
      _Job(port.sendPort, wavPath, vad, whisper, maxSeconds),
      onError: port.sendPort,
    );
    try {
      await for (final message in port) {
        switch (message) {
          case _Progress(:final done, :final total):
            yield TranscriptionProgress(done: done, total: total);
          case _Result(:final texts):
            yield TranscriptionDone(texts);
            return;
          default:
            // onError delivers [error, stack] as strings.
            throw StateError('Transcription failed: $message');
        }
      }
    } finally {
      port.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

class _Job {
  const _Job(this.reply, this.wavPath, this.vad, this.whisper, this.maxSeconds);
  final SendPort reply;
  final String wavPath;
  final String vad;
  final SttModelPaths whisper;
  final int maxSeconds;
}

class _Progress {
  const _Progress(this.done, this.total);
  final int done;
  final int total;
}

class _Result {
  const _Result(this.texts);
  final List<String> texts;
}

void _work(_Job job) {
  final texts = transcribeLongWav(
    wavPath: job.wavPath,
    vadModel: job.vad,
    whisper: job.whisper,
    maxSeconds: job.maxSeconds,
    onProgress: (done, total) => job.reply.send(_Progress(done, total)),
  );
  job.reply.send(_Result(texts));
}
