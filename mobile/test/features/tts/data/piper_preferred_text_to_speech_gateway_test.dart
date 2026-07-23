// Proves the fallback chain: Piper preferred; an absent voice triggers the
// lazy download exactly once AND the system voice covers the utterance; a
// synthesis failure falls back WITHOUT re-triggering a download; the 🔊
// button therefore always works. One-at-a-time holds across engines.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/piper_preferred_text_to_speech_gateway.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';

import '../support/fake_tts.dart';

void main() {
  group('PiperPreferredTextToSpeechGateway', () {
    test('speaks with Piper when the voice is available — no fallback, no download', () async {
      final piper = FakeTextToSpeechGateway();
      final system = FakeTextToSpeechGateway();
      var downloads = 0;
      final gateway = PiperPreferredTextToSpeechGateway(
        preferred: piper,
        fallback: system,
        onVoiceAbsent: () => downloads++,
      );

      await gateway.speak('hola');

      expect(piper.spoken, ['hola']);
      expect(system.spoken, isEmpty);
      expect(downloads, 0);
      // The OTHER engine was stopped first (one utterance at a time).
      expect(system.stops, 1);
    });

    test('voice not downloaded → triggers the download AND uses the system voice', () async {
      final piper =
          FakeTextToSpeechGateway(speakError: PiperVoiceUnavailableException('es'));
      final system = FakeTextToSpeechGateway();
      var downloads = 0;
      final gateway = PiperPreferredTextToSpeechGateway(
        preferred: piper,
        fallback: system,
        onVoiceAbsent: () => downloads++,
      );

      await gateway.speak('hola');

      expect(system.spoken, ['hola']); // the button still worked
      expect(downloads, 1); // Piper next time
    });

    test('synthesis failure → system voice WITHOUT re-triggering a download', () async {
      final piper = FakeTextToSpeechGateway(speakError: PiperSynthesisException('boom'));
      final system = FakeTextToSpeechGateway();
      var downloads = 0;
      final gateway = PiperPreferredTextToSpeechGateway(
        preferred: piper,
        fallback: system,
        onVoiceAbsent: () => downloads++,
      );

      await gateway.speak('hola');

      expect(system.spoken, ['hola']);
      expect(downloads, 0);
    });

    test('ANY unexpected Piper failure still lands on the system voice', () async {
      final piper = FakeTextToSpeechGateway(speakError: StateError('ffi died'));
      final system = FakeTextToSpeechGateway();
      final gateway = PiperPreferredTextToSpeechGateway(preferred: piper, fallback: system);

      await gateway.speak('hola');

      expect(system.spoken, ['hola']);
    });

    test('a dead system-voice channel never blocks Piper speech', () async {
      final piper = FakeTextToSpeechGateway();
      final system = FakeTextToSpeechGateway(stopError: MissingPluginException());
      final gateway = PiperPreferredTextToSpeechGateway(preferred: piper, fallback: system);

      await gateway.speak('hola');

      expect(piper.spoken, ['hola']);
    });

    test('stop stops both engines, even when the preferred throws', () async {
      final piper = FakeTextToSpeechGateway(stopError: StateError('gone'));
      final system = FakeTextToSpeechGateway();
      final gateway = PiperPreferredTextToSpeechGateway(preferred: piper, fallback: system);

      await gateway.stop();

      expect(system.stops, 1);
    });

    test('completions merge natural ends from BOTH engines', () async {
      final piper = FakeTextToSpeechGateway();
      final system = FakeTextToSpeechGateway();
      final gateway = PiperPreferredTextToSpeechGateway(preferred: piper, fallback: system);
      final ends = <void>[];
      final sub = gateway.completions.listen(ends.add);
      addTearDown(sub.cancel);

      piper.emitCompletion();
      system.emitCompletion();
      await Future<void>.delayed(Duration.zero);

      expect(ends, hasLength(2));
    });

    test('dispose disposes both engines and closes the stream', () async {
      final piper = FakeTextToSpeechGateway();
      final system = FakeTextToSpeechGateway();
      final gateway = PiperPreferredTextToSpeechGateway(preferred: piper, fallback: system);

      await gateway.dispose();

      expect(piper.disposed, isTrue);
      expect(system.disposed, isTrue);
      expect(gateway.completions.isBroadcast, isTrue);
    });
  });
}
