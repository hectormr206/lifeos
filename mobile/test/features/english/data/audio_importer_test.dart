// Importing the learner's own audio or video as reading and listening input.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/audio_importer.dart';

class _Decoder implements AudioToWav {
  _Decoder({this.fail = false});
  final bool fail;
  final List<String> inputs = [];

  @override
  Future<void> convert(String input, String wavOut) async {
    inputs.add(input);
    if (fail) throw Exception('cannot decode');
    File(wavOut).writeAsStringSync('RIFF');
  }
}

class _Recognizer implements LongAudioRecognizer {
  _Recognizer(this.chunks, {this.noModel = false});
  final List<String> chunks;
  final bool noModel;
  int? maxSeconds;

  @override
  Stream<TranscriptionEvent> transcribe(String wavPath, {required int maxSeconds}) async* {
    this.maxSeconds = maxSeconds;
    if (noModel) throw const SpeechModelMissing();
    for (var i = 0; i < chunks.length; i++) {
      yield TranscriptionProgress(done: i + 1, total: chunks.length);
    }
    yield TranscriptionDone(chunks);
  }
}

void main() {
  late Directory temp;
  late File picked;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('import-test');
    // A hostile name: quotes and a pipeline-looking tail.
    picked = File('${temp.path}/My "podcast" ! filesink.mp3')..writeAsStringSync('ID3');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  AudioImporter importer(_Decoder decoder, _Recognizer recognizer) => AudioImporter(
        decoder: decoder,
        recognizer: recognizer,
        workDirectory: () async => temp,
      );

  test('the decoder never sees the original name, only a safe copy', () async {
    final decoder = _Decoder();
    await importer(decoder, _Recognizer(['Hello there.'])).importFile(picked.path).drain<void>();

    final seen = decoder.inputs.single.split('/').last;
    expect(seen, matches(RegExp(r'^import-\d+\.mp3$')));
  });

  test('the transcript comes back one chunk per line, titled by the file',
      () async {
    final events = await importer(
      _Decoder(),
      _Recognizer(['Hello there.', '', 'How are you?']),
    ).importFile(picked.path).toList();

    final done = events.whereType<ImportDone>().single;
    expect(done.text, 'Hello there.\nHow are you?');
    expect(done.title, 'My "podcast" ! filesink.mp3');
  });

  test('progress reaches the screen', () async {
    final events = await importer(_Decoder(), _Recognizer(['a b.', 'c d.']))
        .importFile(picked.path)
        .toList();

    expect(events.whereType<ImportProgress>().last.done, 2);
  });

  test('long files are capped, not refused', () async {
    final recognizer = _Recognizer(['x.']);
    await importer(_Decoder(), recognizer).importFile(picked.path).drain<void>();

    expect(recognizer.maxSeconds, kMaxImportSeconds);
  });

  test('temporary audio is deleted, after success and after failure',
      () async {
    await importer(_Decoder(), _Recognizer(['x.'])).importFile(picked.path).drain<void>();
    await importer(_Decoder(fail: true), _Recognizer(['x.']))
        .importFile(picked.path)
        .drain<void>();

    final left = temp.listSync().map((f) => f.path.split('/').last).toList();
    expect(left, ['My "podcast" ! filesink.mp3'], reason: 'only the original stays');
  });

  test('a picker copy the app owns is deleted too, even after a failure',
      () async {
    // Android's picker copies the chosen file into the app cache and never
    // deletes it: a whole podcast would stay there, in the clear.
    final ok = File('${temp.path}/copy-ok.mp3')..writeAsStringSync('ID3');
    final bad = File('${temp.path}/copy-bad.mp3')..writeAsStringSync('ID3');

    await importer(_Decoder(), _Recognizer(['x.']))
        .importFile(ok.path, deleteSourceAfter: true)
        .drain<void>();
    await importer(_Decoder(fail: true), _Recognizer(['x.']))
        .importFile(bad.path, deleteSourceAfter: true)
        .drain<void>();

    expect(ok.existsSync(), isFalse);
    expect(bad.existsSync(), isFalse);
    expect(picked.existsSync(), isTrue, reason: 'without the flag, never');
  });

  test('isInsideDirectory tells an app copy from a file of the learner', () {
    expect(isInsideDirectory('/data/cache/1f2e/talk.mp3', '/data/cache'), isTrue);
    expect(isInsideDirectory('/data/cache', '/data/cache'), isFalse);
    expect(isInsideDirectory('/data/cache-other/talk.mp3', '/data/cache'), isFalse);
    expect(isInsideDirectory('/data/cache/../music/talk.mp3', '/data/cache'), isFalse);
    expect(isInsideDirectory('/home/me/Music/talk.mp3', '/tmp'), isFalse);
  });

  test('a file that cannot be decoded is said as such', () async {
    final events = await importer(_Decoder(fail: true), _Recognizer(['x.']))
        .importFile(picked.path)
        .toList();

    expect(events.last, isA<ImportFailed>()
        .having((e) => e.reason, 'reason', ImportFailure.cannotDecode));
  });

  test('a format that is not audio is refused before decoding', () async {
    final pdf = File('${temp.path}/notes.pdf')..writeAsStringSync('%PDF');
    final decoder = _Decoder();
    final events = await importer(decoder, _Recognizer(['x.'])).importFile(pdf.path).toList();

    expect(events.last, isA<ImportFailed>()
        .having((e) => e.reason, 'reason', ImportFailure.unsupported));
    expect(decoder.inputs, isEmpty);
  });

  test('no speech model is its own reason, so the screen can point to it',
      () async {
    final events = await importer(_Decoder(), _Recognizer(const [], noModel: true))
        .importFile(picked.path)
        .toList();

    expect(events.last, isA<ImportFailed>()
        .having((e) => e.reason, 'reason', ImportFailure.noSpeechModel));
  });

  test('nothing heard is not an error, but it is said', () async {
    final events = await importer(_Decoder(), _Recognizer(const ['', ' ']))
        .importFile(picked.path)
        .toList();

    expect(events.last, isA<ImportFailed>()
        .having((e) => e.reason, 'reason', ImportFailure.nothingHeard));
  });
}
