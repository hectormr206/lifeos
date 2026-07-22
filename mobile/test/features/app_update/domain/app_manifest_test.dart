// Proves AppManifest.fromJson parses the engine manifest shape
// (axi/src/axi/app_updates.py) and rejects a malformed payload.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';

void main() {
  group('AppManifest.fromJson', () {
    test('parses a full manifest', () {
      final m = AppManifest.fromJson({
        'versionCode': 12,
        'versionName': '1.4.0',
        'apkFilename': 'lifeos-1.4.0-12.apk',
        'sha256': 'ABC123',
        'sizeBytes': 150000000,
        'notes': 'Nuevas mejoras',
        'publishedAt': '2026-07-20T00:00:00+00:00',
      });
      expect(m.versionCode, 12);
      expect(m.versionName, '1.4.0');
      expect(m.apkFilename, 'lifeos-1.4.0-12.apk');
      expect(m.sha256, 'ABC123');
      expect(m.sizeBytes, 150000000);
      expect(m.notes, 'Nuevas mejoras');
    });

    test('coerces a stringified versionCode/sizeBytes', () {
      final m = AppManifest.fromJson({'versionCode': '7', 'sizeBytes': '42'});
      expect(m.versionCode, 7);
      expect(m.sizeBytes, 42);
      expect(m.notes, '');
    });

    test('throws FormatException when versionCode is missing', () {
      expect(() => AppManifest.fromJson({'versionName': '1.0.0'}), throwsFormatException);
    });

    test('throws FormatException when versionCode is unparseable', () {
      expect(() => AppManifest.fromJson({'versionCode': 'not-a-number'}), throwsFormatException);
    });
  });
}
