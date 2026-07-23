// Proves the language mapping the STT service uses to pin the multilingual
// Whisper recognizer: the i18n app-language code selects the recognizer
// language ('es'/'en'), with an unknown code defaulting to Spanish (the app's
// neutral default).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/stt/domain/speech_to_text.dart';

void main() {
  group('sttWhisperLanguage', () {
    test('English app language selects the English recognizer', () {
      expect(sttWhisperLanguage('en'), 'en');
    });

    test('Spanish app language selects the Spanish recognizer', () {
      expect(sttWhisperLanguage('es'), 'es');
    });

    test('an unknown language falls back to Spanish (neutral default)', () {
      expect(sttWhisperLanguage('fr'), 'es');
      expect(sttWhisperLanguage(''), 'es');
    });
  });

  test('SttException carries and prints its message', () {
    final e = SttException('no model');
    expect(e.message, 'no model');
    expect(e.toString(), 'no model');
  });
}
