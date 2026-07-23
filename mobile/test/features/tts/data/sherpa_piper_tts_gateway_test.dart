// Proves the Piper gateway: voice selection follows the CURRENT app language,
// an absent voice surfaces as PiperVoiceUnavailableException (never a crash),
// synthesized PCM is played as a WAV, and stop() cancels an in-flight
// synthesis so its late result is discarded.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/sherpa_piper_tts_gateway.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';

import '../support/fake_tts.dart';

const _esVoice = TtsVoicePaths(model: 'es.onnx', tokens: 'es.tokens.txt', dataDir: 'espeak');
const _enVoice = TtsVoicePaths(model: 'en.onnx', tokens: 'en.tokens.txt', dataDir: 'espeak');

void main() {
  group('SherpaPiperTtsGateway', () {
    late FakeTtsVoiceGateway voices;
    late FakeSynthesizer synthesizer;
    late FakePlayback playback;
    late String language;

    SherpaPiperTtsGateway build() => SherpaPiperTtsGateway(
          voiceGateway: voices,
          synthesizer: synthesizer,
          playback: playback,
          currentLanguageCode: () => language,
        );

    setUp(() {
      voices = FakeTtsVoiceGateway(installed: {'es': _esVoice, 'en': _enVoice});
      synthesizer = FakeSynthesizer();
      playback = FakePlayback();
      language = 'es';
    });

    test('speak synthesizes with the voice of the CURRENT language', () async {
      final gateway = build();

      await gateway.speak('hola');
      language = 'en';
      await gateway.speak('hello');

      expect(synthesizer.calls, hasLength(2));
      expect(synthesizer.calls[0].$1.model, 'es.onnx');
      expect(synthesizer.calls[0].$2, 'hola');
      expect(synthesizer.calls[1].$1.model, 'en.onnx');
    });

    test('speak plays the synthesized PCM wrapped as a WAV', () async {
      synthesizer = FakeSynthesizer(
        audio: SynthesizedAudio(samples: Float32List.fromList([0.0, 1.0]), sampleRate: 22050),
      );
      final gateway = build();

      await gateway.speak('hola');

      expect(playback.played, hasLength(1));
      final wav = playback.played.single;
      expect(String.fromCharCodes(wav, 0, 4), 'RIFF');
      expect(wav.length, 44 + 2 * 2); // header + two 16-bit samples
      // Stopped any previous utterance before playing (one at a time).
      expect(playback.stops, 1);
    });

    test('an absent voice throws PiperVoiceUnavailableException without synthesizing', () async {
      voices = FakeTtsVoiceGateway(installed: {}); // nothing downloaded yet
      final gateway = build();

      await expectLater(
        gateway.speak('hola'),
        throwsA(isA<PiperVoiceUnavailableException>()),
      );
      expect(synthesizer.calls, isEmpty);
      expect(playback.played, isEmpty);
    });

    test('a language without a Piper voice is unavailable too', () async {
      language = 'fr';
      final gateway = build();

      await expectLater(
        gateway.speak('bonjour'),
        throwsA(isA<PiperVoiceUnavailableException>()),
      );
    });

    test('blank text is a no-op', () async {
      final gateway = build();

      await gateway.speak('   ');

      expect(synthesizer.calls, isEmpty);
      expect(playback.played, isEmpty);
    });

    test('stop() during synthesis discards the late result (nothing plays)', () async {
      synthesizer.gate = Completer<void>();
      final gateway = build();

      final speaking = gateway.speak('hola');
      await gateway.stop();
      synthesizer.gate!.complete();
      await speaking;

      expect(playback.played, isEmpty);
    });

    test('a newer speak supersedes an in-flight synthesis', () async {
      synthesizer.gate = Completer<void>();
      final gateway = build();

      final first = gateway.speak('primera');
      final gate = synthesizer.gate!;
      synthesizer.gate = null;
      await gateway.speak('segunda'); // completes fully (no gate)
      gate.complete(); // now the stale first synthesis lands
      await first;

      expect(playback.played, hasLength(1)); // only "segunda" reached playback
    });

    test('completions passes through natural playback ends', () async {
      final gateway = build();
      final ends = <void>[];
      final sub = gateway.completions.listen(ends.add);
      addTearDown(sub.cancel);

      playback.emitCompletion();
      await Future<void>.delayed(Duration.zero);

      expect(ends, hasLength(1));
    });

    test('dispose releases the player', () async {
      final gateway = build();

      await gateway.dispose();

      expect(playback.disposed, isTrue);
    });
  });
}
