// Proves the Piper voice manifest: any voice id resolves to its flat hosted
// filenames (`<id>.onnx` + `.onnx.json`), the derived (never hosted) tokens
// name, the size floors, and the placeholder-URL guard.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/tts_voice_source_config.dart';

void main() {
  group('TtsVoiceSourceConfig', () {
    const config = TtsVoiceSourceConfig();

    test('a voice id resolves to its flat <id>.onnx / <id>.onnx.json files', () {
      final voice = config.specForVoice('es_MX-claude');
      expect(voice.model.name, 'es_MX-claude.onnx');
      expect(voice.config.name, 'es_MX-claude.onnx.json');
      expect(voice.tokensFileName, 'es_MX-claude.onnx.tokens.txt');
    });

    test('a different voice id resolves to its own files (no hardcoded case)', () {
      final voice = config.specForVoice('en_GB-alan');
      expect(voice.model.name, 'en_GB-alan.onnx');
      expect(voice.config.name, 'en_GB-alan.onnx.json');
      expect(voice.files.map((f) => f.name), ['en_GB-alan.onnx', 'en_GB-alan.onnx.json']);
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
      final voice = config.specForVoice('es_ES-davefx');
      expect(voice.model.minBytes, greaterThanOrEqualTo(1024 * 1024));
      expect(voice.config.minBytes, greaterThan(0));
    });
  });
}
