// Proves the Piper gateway: synthesis uses the SELECTED voice's resolved path,
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

const _claudeVoice =
    TtsVoicePaths(model: 'es_MX-claude.onnx', tokens: 'es_MX-claude.tokens.txt', dataDir: 'espeak');
const _alanVoice =
    TtsVoicePaths(model: 'en_GB-alan.onnx', tokens: 'en_GB-alan.tokens.txt', dataDir: 'espeak');

void main() {
  group('SherpaPiperTtsGateway', () {
    late FakeTtsVoiceGateway voices;
    late FakeSynthesizer synthesizer;
    late FakePlayback playback;
    late String voiceId;

    SherpaPiperTtsGateway build() => SherpaPiperTtsGateway(
          voiceGateway: voices,
          synthesizer: synthesizer,
          playback: playback,
          currentVoiceId: () => voiceId,
        );

    setUp(() {
      voices = FakeTtsVoiceGateway(
          installed: {'es_MX-claude': _claudeVoice, 'en_GB-alan': _alanVoice});
      synthesizer = FakeSynthesizer();
      playback = FakePlayback();
      voiceId = 'es_MX-claude';
    });

    test('speak synthesizes with the SELECTED voice path', () async {
      final gateway = build();

      await gateway.speak('hola');
      voiceId = 'en_GB-alan';
      await gateway.speak('hello');

      expect(synthesizer.calls, hasLength(2));
      expect(synthesizer.calls[0].$1.model, 'es_MX-claude.onnx');
      expect(synthesizer.calls[0].$2, 'hola');
      expect(synthesizer.calls[1].$1.model, 'en_GB-alan.onnx');
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

    test('an uninstalled selected voice is unavailable too', () async {
      voiceId = 'es_AR-daniela'; // known catalog voice, just not downloaded
      final gateway = build();

      await expectLater(
        gateway.speak('hola'),
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
