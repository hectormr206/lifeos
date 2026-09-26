// Fakes for the Piper synthesizer and the player, shared by the English
// listening tests.
import 'dart:async';
import 'dart:typed_data';

import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_playback.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';

class FakeSynth implements PiperSpeechSynthesizer {
  final List<String> texts = [];
  final List<double> speeds = [];
  String? failOn;

  @override
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    texts.add(text);
    speeds.add(speed);
    if (text == failOn) throw Exception('synthesis failed');
    return SynthesizedAudio(samples: Float32List(8), sampleRate: 22050);
  }
}

class FakePlayback implements TtsPlayback {
  final _ends = StreamController<void>.broadcast();
  int plays = 0;
  int stops = 0;

  /// Ends the current sentence, as the player would.
  void finish() => _ends.add(null);

  @override
  Future<void> play(Uint8List wavBytes) async => plays++;

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<void> get completions => _ends.stream;

  @override
  Future<void> dispose() => _ends.close();
}
