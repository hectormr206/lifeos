// Proves the local tokens.txt derivation from a Piper voice's *.onnx.json —
// the same `<symbol> <id>` table sherpa-onnx's piper conversion script writes.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/piper_tokens.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';

void main() {
  group('piperTokensFromConfigJson', () {
    test('writes one "<symbol> <id>" line per phoneme_id_map entry', () {
      const json = '{"phoneme_id_map": {"_": [0], "^": [1], "a": [4]}}';
      expect(piperTokensFromConfigJson(json), '_ 0\n^ 1\na 4\n');
    });

    test('keeps the space symbol as a literal leading space', () {
      const json = '{"phoneme_id_map": {" ": [3]}}';
      expect(piperTokensFromConfigJson(json), '  3\n');
    });

    test('uses the FIRST id when a symbol maps to several', () {
      const json = '{"phoneme_id_map": {"a": [4, 9]}}';
      expect(piperTokensFromConfigJson(json), 'a 4\n');
    });

    test('rejects invalid JSON', () {
      expect(() => piperTokensFromConfigJson('<html>error'), throwsA(isA<PiperTokensException>()));
    });

    test('rejects a config without phoneme_id_map', () {
      expect(() => piperTokensFromConfigJson('{"audio": {}}'), throwsA(isA<PiperTokensException>()));
      expect(
        () => piperTokensFromConfigJson('{"phoneme_id_map": {}}'),
        throwsA(isA<PiperTokensException>()),
      );
    });

    test('rejects a malformed map entry', () {
      expect(
        () => piperTokensFromConfigJson('{"phoneme_id_map": {"a": "4"}}'),
        throwsA(isA<PiperTokensException>()),
      );
    });
  });

  group('assertPiperVoiceCompatible', () {
    test('accepts a valid espeak single-speaker config', () {
      const json = '{"phoneme_type": "espeak", "num_speakers": 1}';
      expect(() => assertPiperVoiceCompatible(json), returnsNormally);
    });

    test('accepts an espeak config with num_speakers absent', () {
      const json = '{"phoneme_type": "espeak"}';
      expect(() => assertPiperVoiceCompatible(json), returnsNormally);
    });

    test('rejects a config missing phoneme_type (crashes sherpa natively)', () {
      const json = '{"num_speakers": 1}';
      expect(
        () => assertPiperVoiceCompatible(json),
        throwsA(isA<UnsupportedVoiceException>()),
      );
    });

    test('rejects a non-espeak phoneme_type', () {
      const json = '{"phoneme_type": "text", "num_speakers": 1}';
      expect(
        () => assertPiperVoiceCompatible(json),
        throwsA(isA<UnsupportedVoiceException>()),
      );
    });

    test('rejects a multi-speaker config (num_speakers > 1)', () {
      const json = '{"phoneme_type": "espeak", "num_speakers": 904}';
      expect(
        () => assertPiperVoiceCompatible(json),
        throwsA(isA<UnsupportedVoiceException>()),
      );
    });

    test('rejects invalid JSON', () {
      expect(
        () => assertPiperVoiceCompatible('<html>error'),
        throwsA(isA<UnsupportedVoiceException>()),
      );
    });
  });
}
