import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/sherpa_piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('piper-synth-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('missing paired JSON is caught before entering native code', () async {
    final voice = TtsVoicePaths(
      model: '${temp.path}/voice.onnx',
      tokens: '${temp.path}/tokens.txt',
      dataDir: temp.path,
    );
    await expectLater(
      const SherpaPiperSpeechSynthesizer().synthesize(voice: voice, text: 'Hello'),
      throwsA(isA<UnsupportedVoiceException>()),
    );
  });

  test('invalid paired JSON is caught in isolate without crashing', () async {
    final config = File('${temp.path}/voice.onnx.json')..writeAsStringSync('invalid');
    File('${temp.path}/tokens.txt').writeAsStringSync('a 1\n');
    File('${temp.path}/phontab').writeAsBytesSync([0]);
    final voice = TtsVoicePaths(
      model: '${temp.path}/voice.onnx',
      config: config.path,
      tokens: '${temp.path}/tokens.txt',
      dataDir: temp.path,
    );
    await expectLater(
      const SherpaPiperSpeechSynthesizer().synthesize(voice: voice, text: 'Hello'),
      throwsA(isA<UnsupportedVoiceException>()),
    );
  });
}
