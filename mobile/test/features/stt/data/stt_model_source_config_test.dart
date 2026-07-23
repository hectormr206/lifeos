// Proves the STT model source config: the placeholder base URL is treated as
// unconfigured (so download degrades gracefully instead of hitting a bogus
// host), a real URL is configured, and the three-file manifest carries
// sensible size floors for the sanity check.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/stt/data/stt_model_source_config.dart';

void main() {
  group('SttModelSourceConfig', () {
    test('the default (placeholder) base URL is NOT configured', () {
      const config = SttModelSourceConfig();
      expect(config.baseUrl.contains('PLACEHOLDER'), isTrue);
      expect(config.isConfigured, isFalse);
    });

    test('a real base URL is configured', () {
      const config = SttModelSourceConfig(baseUrl: 'https://models.example/lifeos/stt');
      expect(config.isConfigured, isTrue);
    });

    test('an empty base URL is NOT configured', () {
      const config = SttModelSourceConfig(baseUrl: '');
      expect(config.isConfigured, isFalse);
    });

    test('exposes the three whisper files with size floors, in download order', () {
      const config = SttModelSourceConfig();
      expect(config.files.map((f) => f.name), [
        'base-encoder.int8.onnx',
        'base-decoder.int8.onnx',
        'base-tokens.txt',
      ]);
      // Encoder/decoder must be at least ~1 MB; tokens at least ~1 KB. This is
      // what catches a truncated download or a captive-portal HTML page.
      expect(config.encoder.minBytes, greaterThanOrEqualTo(1024 * 1024));
      expect(config.decoder.minBytes, greaterThanOrEqualTo(1024 * 1024));
      expect(config.tokens.minBytes, greaterThanOrEqualTo(1024));
    });
  });
}
