import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/piper_model_metadata.dart';
import 'package:lifeos/features/tts/data/piper_tokens.dart';
import 'package:lifeos/features/tts/data/sherpa_piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';

const english = '{"phoneme_type":"espeak","num_speakers":1,"audio":{"sample_rate":22050},"lang_code":"en_US","espeak":{"voice":"en-us"}}';
const spanish = '{"phoneme_type":"espeak","num_speakers":1,"audio":{"sample_rate":22500},"lang_code":"es_AR","espeak":{"voice":"es"}}';

List<int> varint(int n) {
  final bytes = <int>[];
  while (n > 127) {
    bytes.add((n & 127) | 128);
    n >>= 7;
  }
  return [...bytes, n];
}

List<int> field(int number, List<int> bytes) => [
      ...varint((number << 3) | 2), ...varint(bytes.length), ...bytes,
    ];

List<int> entry(String key, String value) => field(14, [
      ...field(1, key.codeUnits), ...field(2, value.codeUnits),
    ]);

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('piper-preparation-'));
  tearDown(() => temp.deleteSync(recursive: true));

  File model(List<int> bytes) => File('${temp.path}/voice.onnx')..writeAsBytesSync(bytes);
  final graph = field(7, List.filled(32768, 42));

  test('derives complete Piper metadata without changing the original weights', () {
    final source = model(graph);
    final before = source.readAsBytesSync();
    final prepared = preparePiperModel(source.path, english);
    expect(prepared, isNot(source.path));
    expect(File(prepared).readAsBytesSync().sublist(0, before.length), before);
    expect(source.readAsBytesSync(), before);
    expect(readPiperModelMetadata(prepared), containsPair('sample_rate', '22050'));
    expect(readPiperModelMetadata(prepared), containsPair('n_speakers', '1'));
    expect(readPiperModelMetadata(prepared), containsPair('comment', 'piper'));
    expect(readPiperModelMetadata(prepared), containsPair('language', 'English'));
    expect(readPiperModelMetadata(prepared), containsPair('voice', 'en_US'));
    expect(readPiperModelMetadata(prepared), containsPair('has_espeak', '1'));
    expect(readPiperModelMetadata(prepared), containsPair('model_type', 'vits'));
  });

  test('already compatible model is unchanged and Spanish sample rate normalized', () {
    final source = model(graph);
    final derived = preparePiperModel(source.path, spanish);
    expect(readPiperModelMetadata(derived), containsPair('language', 'Spanish'));
    expect(readPiperModelMetadata(derived), containsPair('sample_rate', '22050'));
    final converted = model(File(derived).readAsBytesSync());
    expect(preparePiperModel(converted.path, spanish), converted.path);
  });

  test('uses cache on repeated calls; invalidates on changed source or JSON', () {
    final source = model(graph);
    final first = preparePiperModel(source.path, english);
    final stamp = File(first).lastModifiedSync();
    expect(preparePiperModel(source.path, english), first);
    expect(File(first).lastModifiedSync(), stamp);
    final changedJson = english.replaceFirst('22050', '24000');
    final second = preparePiperModel(source.path, changedJson);
    expect(second, isNot(first));
    final modified = [...graph];
    modified[modified.length - 1] = 43; // same size, different weights
    source.writeAsBytesSync(modified);
    final third = preparePiperModel(source.path, changedJson);
    expect(third, isNot(second));
    File(third).writeAsBytesSync([0]); // interrupted/corrupted cached output
    expect(preparePiperModel(source.path, changedJson), third);
    expect(readPiperModelMetadata(third), containsPair('sample_rate', '24000'));
  });

  test('never repairs conflicting or unsafe native metadata', () {
    for (final unsafe in [
      entry('comment', 'not-piper'),
      entry('language', 'Spanish'),
      entry('sample_rate', '99999'),
      entry('n_speakers', '2'),
      entry('has_espeak', '0'),
    ]) {
      final source = model([...graph, ...unsafe]);
      expect(() => preparePiperModel(source.path, english),
          throwsA(isA<UnsupportedVoiceException>()));
    }
  });

  test('rejects malformed model/JSON and does not publish a partial cache', () {
    final source = model([0x72, 0xff, 0xff]);
    expect(() => preparePiperModel(source.path, english),
        throwsA(isA<UnsupportedVoiceException>()));
    source.writeAsBytesSync(graph);
    for (final bad in [
      '{}', 'bad', english.replaceFirst('"espeak"', '"text"'),
      english.replaceFirst('"voice":"en-us"', '"voice":"es"'),
      english.replaceFirst('"sample_rate":22050', '"sample_rate":0'),
    ]) {
      expect(() => preparePiperModel(source.path, bad),
          throwsA(isA<UnsupportedVoiceException>()));
    }
  });

  test('skips a legal ten-byte int64 model field without loading weights', () {
    final source = model([0x28, ...List.filled(9, 0xff), 0x01, ...graph]);
    expect(() => preparePiperModel(source.path, english), returnsNormally);
  });

  test('does not accept sample_rate text in graph or duplicate conflicting keys', () {
    final source = model([...field(7, 'sample_rate'.codeUnits), ...entry('sample_rate', '22050'), ...entry('sample_rate', '99999')]);
    expect(() => preparePiperModel(source.path, english),
        throwsA(isA<UnsupportedVoiceException>()));
  });

  test('simultaneous preparations publish one complete derivative', () async {
    final source = model(graph);
    final paths = await Future.wait([
      for (var i = 0; i < 3; i++) Isolate.run(() => preparePiperModel(source.path, english)),
    ]);
    expect(paths.toSet(), hasLength(1));
    expect(readPiperModelMetadata(paths.first), containsPair('comment', 'piper'));
    expect(temp.listSync().where((f) => f.path.contains('.part.')), isEmpty);
  });

  final fixtures = Platform.environment['PIPER_NATIVE_FIXTURES'];
  test('real public English and Spanish Piper weights produce finite PCM twice', () async {
    for (final (name, sentence) in [
      ('en_US-lessac-medium', 'Hello, this is a reading test.'),
      ('es_AR-daniela-high', 'Hola, esta es una prueba de voz.'),
    ]) {
      final config = File('$fixtures/$name.onnx.json');
      final json = config.readAsStringSync();
      final source = '$fixtures/$name.onnx';
      expect(readPiperModelMetadata(source), isNot(contains('sample_rate')));
      if (name == 'en_US-lessac-medium') {
        final converted = '$fixtures/vits-piper-$name/$name.onnx';
        expect(preparePiperModel(converted, json), converted);
      }
      final tokens = File('${temp.path}/$name.tokens.txt')
        ..writeAsStringSync(piperTokensFromConfigJson(json));
      final voice = TtsVoicePaths(
        model: source, config: config.path, tokens: tokens.path,
        dataDir: '$fixtures/vits-piper-en_US-lessac-medium/espeak-ng-data',
      );
      final synth = const SherpaPiperSpeechSynthesizer();
      for (var i = 0; i < 2; i++) {
        final audio = await synth.synthesize(voice: voice, text: sentence);
        expect(audio.sampleRate, 22050);
        expect(audio.samples, isNotEmpty);
        expect(audio.samples.every((s) => s.isFinite), isTrue);
        expect(audio.samples.any((s) => s.abs() > 0.001), isTrue);
        // Acoustic quality still needs the device; this is real native PCM.
        // ignore: avoid_print
        print('$name pass ${i + 1}: ${audio.samples.length} samples at ${audio.sampleRate} Hz');
      }
      expect(preparePiperModel(source, json), isNot(source));
    }
  }, skip: fixtures == null ? 'Public native model fixtures not supplied' : false);
}
