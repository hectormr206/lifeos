// Proves the Piper voice manifest: exact hosted filenames per language, the
// derived (never hosted) tokens name, and the placeholder-URL guard.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/tts_voice_source_config.dart';

void main() {
  group('TtsVoiceSourceConfig', () {
    const config = TtsVoiceSourceConfig();

    test('es maps to the es_MX-ald-medium Piper voice files', () {
      final voice = config.voiceForLanguage('es');
      expect(voice, isNotNull);
      expect(voice!.model.name, 'es_MX-ald-medium.onnx');
      expect(voice.config.name, 'es_MX-ald-medium.onnx.json');
      expect(voice.tokensFileName, 'es_MX-ald-medium.onnx.tokens.txt');
    });

    test('en maps to the en_US-lessac-medium Piper voice files', () {
      final voice = config.voiceForLanguage('en');
      expect(voice, isNotNull);
      expect(voice!.model.name, 'en_US-lessac-medium.onnx');
      expect(voice.config.name, 'en_US-lessac-medium.onnx.json');
      expect(voice.tokensFileName, 'en_US-lessac-medium.onnx.tokens.txt');
    });

    test('an unsupported language has no Piper voice (system voice covers it)', () {
      expect(config.voiceForLanguage('fr'), isNull);
      expect(config.voiceForLanguage(''), isNull);
    });

    test('shared espeak-ng-data archive is a gzip tar with a size floor', () {
      expect(config.espeakData.name, 'espeak-ng-data.tar.gz');
      expect(config.espeakData.minBytes, greaterThan(0));
      expect(TtsVoiceSourceConfig.espeakDataDirName, 'espeak-ng-data');
    });

    test('placeholder base URL reads as not configured', () {
      expect(config.isConfigured, isFalse);
      expect(const TtsVoiceSourceConfig(baseUrl: '').isConfigured, isFalse);
      expect(
        const TtsVoiceSourceConfig(baseUrl: 'https://models.real.example/tts').isConfigured,
        isTrue,
      );
    });

    test('model size floors reject an error page / truncated download', () {
      expect(config.spanish.model.minBytes, greaterThanOrEqualTo(1024 * 1024));
      expect(config.english.model.minBytes, greaterThanOrEqualTo(1024 * 1024));
      expect(config.spanish.config.minBytes, greaterThan(0));
    });
  });
}
