// Reading a passage aloud, sentence by sentence.
//
// A whole passage is a minute or two of audio; synthesizing it in one go on a
// phone would mean a long silence before the first word. So it is spoken one
// sentence at a time, with the NEXT sentence synthesized while the current
// one plays, and the screen told which sentence is playing so it can follow
// along in the text.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/passage_speaker.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_playback.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';

class _FakeSynth implements PiperSpeechSynthesizer {
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

class _FakePlayback implements TtsPlayback {
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

const _voice = TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd');

void main() {
  late _FakeSynth synth;
  late _FakePlayback playback;
  late PassageSpeaker speaker;

  setUp(() {
    synth = _FakeSynth();
    playback = _FakePlayback();
    speaker = PassageSpeaker(synthesizer: synth, playback: playback);
  });

  test('it says each sentence in order and reports which one is playing',
      () async {
    final started = <int>[];
    final done = speaker
        .speak(const ['One.', 'Two.', 'Three.'], voice: _voice)
        .forEach(started.add);

    for (var i = 0; i < 3; i++) {
      await pumpEventQueue();
      playback.finish();
    }
    await done;

    expect(synth.texts, ['One.', 'Two.', 'Three.']);
    expect(started, [0, 1, 2]);
    expect(playback.plays, 3);
  });

  test('the next sentence is ready before the current one ends', () async {
    unawaited(speaker.speak(const ['One.', 'Two.'], voice: _voice).drain<void>());
    await pumpEventQueue();

    expect(playback.plays, 1);
    expect(synth.texts, ['One.', 'Two.'], reason: 'no gap between sentences');
  });

  test('the chosen speed reaches the voice', () async {
    unawaited(speaker
        .speak(const ['One.'], voice: _voice, speed: kSlowSpeed)
        .drain<void>());
    await pumpEventQueue();

    expect(synth.speeds.single, kSlowSpeed);
  });

  test('stopping means nothing else plays, and the listening ends', () async {
    final done = speaker.speak(const ['One.', 'Two.', 'Three.'], voice: _voice)
        .drain<void>();
    await pumpEventQueue();

    await speaker.stop();
    playback.finish(); // a late "ended" from the player must not resume it
    await done;

    expect(playback.plays, 1);
    expect(playback.stops, 1);
  });

  test('a sentence that cannot be synthesized is reported, not skipped '
      'in silence', () async {
    synth.failOn = 'Two.';
    final stream = speaker.speak(const ['One.', 'Two.'], voice: _voice);

    final done = expectLater(stream, emitsInOrder([0, emitsError(anything)]));
    await pumpEventQueue();
    playback.finish();
    await done;
  });

  group('choosing an English voice', () {
    const ids = ['en_US-lessac', 'en_US-amy', 'en_US-joe'];

    test('none installed means none, so the screen can offer a download', () {
      expect(pickEnglishVoice(const [], seed: 1), isNull);
    });

    test('only English voices are candidates', () {
      expect(pickEnglishVoice(const ['es_MX-claude'], seed: 1), isNull);
    });

    test('the same passage always gets the same voice', () {
      expect(pickEnglishVoice(ids, seed: 42), pickEnglishVoice(ids, seed: 42));
    });

    test('different passages get different speakers', () {
      final voices = {
        for (var seed = 0; seed < 30; seed++) pickEnglishVoice(ids, seed: seed),
      };
      expect(voices.length, greaterThan(1));
    });
  });
}
