// Shared fakes for the on-device Piper TTS tests (roadmap slice B3) — keep
// the sherpa engine, the downloader, and the audio player out of unit tests.
import 'dart:async';
import 'dart:typed_data';

import 'package:lifeos/features/chat/domain/text_to_speech_gateway.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_playback.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/domain/tts_voice_gateway.dart';

/// [TtsVoiceGateway] with a per-voice-id installed map and scripted download.
/// Presence of a voice id in [installed] models "both files (.onnx + .onnx.json)
/// present" — the concrete gateway's installed criterion.
class FakeTtsVoiceGateway implements TtsVoiceGateway {
  FakeTtsVoiceGateway({
    Map<String, TtsVoicePaths>? installed,
    this.downloadError,
    this.downloadProgress = const [1.0],
    this.deleteError,
  }) : installed = installed ?? {};

  final Map<String, TtsVoicePaths> installed;
  final Object? downloadError;
  final List<double> downloadProgress;
  final Object? deleteError;
  final List<String> downloadCalls = [];
  final List<String> deleteCalls = [];

  /// When set, every download parks on this gate BEFORE landing installed, so a
  /// test can hold several downloads in flight at once and prove that starting
  /// one never cancels/freezes another (the shared-group deadlock regression).
  Completer<void>? downloadGate;

  @override
  Future<TtsVoicePaths?> installedVoice(String voiceId) async => installed[voiceId];

  @override
  Future<TtsVoicePaths> download(
    String voiceId, {
    void Function(double progress)? onProgress,
  }) async {
    downloadCalls.add(voiceId);
    final error = downloadError;
    if (error != null) throw error;
    for (final p in downloadProgress) {
      onProgress?.call(p);
    }
    final gate = downloadGate;
    if (gate != null) await gate.future;
    final paths = TtsVoicePaths(
      model: '$voiceId.onnx',
      tokens: '$voiceId.tokens.txt',
      dataDir: 'espeak-ng-data',
    );
    installed[voiceId] = paths;
    return paths;
  }

  @override
  Future<void> deleteVoice(String voiceId) async {
    deleteCalls.add(voiceId);
    final error = deleteError;
    if (error != null) throw error;
    installed.remove(voiceId);
  }
}

/// [PiperSpeechSynthesizer] returning scripted audio (or failing), with an
/// optional gate so tests can hold a synthesis "in flight".
class FakeSynthesizer implements PiperSpeechSynthesizer {
  FakeSynthesizer({SynthesizedAudio? audio, this.error})
      : audio = audio ??
            SynthesizedAudio(
              samples: Float32List.fromList([0.0, 0.5, -0.5]),
              sampleRate: 22050,
            );

  final SynthesizedAudio audio;
  final Object? error;

  /// When set, synthesize awaits this before returning (test-controlled gate).
  Completer<void>? gate;

  final List<(TtsVoicePaths, String)> calls = [];

  /// The [speed] passed to the most recent [synthesize] (default 1.0), so tests
  /// can assert the persisted "Voz" rate reached the engine.
  double lastSpeed = 1.0;

  @override
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    calls.add((voice, text));
    lastSpeed = speed;
    final pending = gate;
    if (pending != null) await pending.future;
    final e = error;
    if (e != null) throw e;
    return audio;
  }
}

/// [TtsPlayback] recording played bytes; completions are test-driven.
class FakePlayback implements TtsPlayback {
  final List<Uint8List> played = [];
  int stops = 0;
  bool disposed = false;
  final StreamController<void> _completions = StreamController<void>.broadcast();

  void emitCompletion() => _completions.add(null);

  @override
  Future<void> play(Uint8List wavBytes) async => played.add(wavBytes);

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _completions.close();
  }
}

/// Recording [TextToSpeechGateway] for composite/fallback tests.
class FakeTextToSpeechGateway implements TextToSpeechGateway {
  FakeTextToSpeechGateway({this.speakError, this.stopError});

  final Object? speakError;
  final Object? stopError;
  final List<String> spoken = [];
  int stops = 0;
  bool disposed = false;
  final StreamController<void> _completions = StreamController<void>.broadcast();

  void emitCompletion() => _completions.add(null);

  @override
  Future<void> speak(String text) async {
    final e = speakError;
    if (e != null) throw e;
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    final e = stopError;
    if (e != null) throw e;
    stops++;
  }

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _completions.close();
  }
}
