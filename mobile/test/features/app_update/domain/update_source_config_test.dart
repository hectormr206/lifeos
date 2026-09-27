import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';

void main() {
  test('explicit config retains overrides', () {
    const config = UpdateSourceConfig(
      baseUrl: 'https://updates.test.example/lifeos',
      accessKey: 'fake-key',
    );
    expect(config.baseUrl, 'https://updates.test.example/lifeos');
    expect(config.accessKey, 'fake-key');
    expect(config.isConfigured, isTrue);
  });

  test('environment constructor consumes the configured defines', () {
    const config = UpdateSourceConfig.fromEnvironment();
    expect(config.baseUrl, kUpdateBaseUrl);
    expect(config.accessKey, kUpdateAccessKey);
    expect(config.isConfigured,
        kUpdateBaseUrl.isNotEmpty &&
            kUpdateAccessKey.isNotEmpty &&
            !kUpdateBaseUrl.contains('PLACEHOLDER') &&
            !kUpdateAccessKey.contains('PLACEHOLDER'));
  });

  test('explicit empty or placeholder config is unconfigured', () {
    for (final config in [
      const UpdateSourceConfig(baseUrl: '', accessKey: 'fake-key'),
      const UpdateSourceConfig(
        baseUrl: 'https://updates.PLACEHOLDER.example/lifeos',
        accessKey: 'fake-key',
      ),
      const UpdateSourceConfig(
        baseUrl: 'https://updates.test.example/lifeos',
        accessKey: 'PLACEHOLDER_UPDATE_ACCESS_KEY',
      ),
    ]) {
      expect(config.isConfigured, isFalse);
    }
  });
}
