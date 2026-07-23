// Proves BrainModelManifest parses the VPS manifest.json contract
// ({modelName, versionCode, filename, sha256, sizeBytes, notes, publishedAt}),
// hard-fails on a missing/invalid versionCode (a malformed manifest must never
// read as "no update"), and tolerates missing string fields.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/brain_model_manifest.dart';

void main() {
  test('parses a complete manifest', () {
    final manifest = BrainModelManifest.fromJson(const {
      'modelName': 'gemma-4-E2B-it',
      'versionCode': 3,
      'filename': 'gemma-4-E2B-it.litertlm',
      'sha256': 'deadbeef',
      'sizeBytes': 2590000000,
      'notes': 'Recipe re-tuned',
      'publishedAt': '2026-07-23T00:00:00Z',
    });
    expect(manifest.modelName, 'gemma-4-E2B-it');
    expect(manifest.versionCode, 3);
    expect(manifest.filename, 'gemma-4-E2B-it.litertlm');
    expect(manifest.sha256, 'deadbeef');
    expect(manifest.sizeBytes, 2590000000);
    expect(manifest.notes, 'Recipe re-tuned');
    expect(manifest.publishedAt, '2026-07-23T00:00:00Z');
  });

  test('throws FormatException when versionCode is missing', () {
    expect(
      () => BrainModelManifest.fromJson(const {'modelName': 'gemma-4-E2B-it'}),
      throwsFormatException,
    );
  });

  test('throws FormatException when versionCode is garbage', () {
    expect(
      () => BrainModelManifest.fromJson(const {'versionCode': 'not-a-number'}),
      throwsFormatException,
    );
  });

  test('tolerates a numeric-string versionCode and missing string fields', () {
    final manifest = BrainModelManifest.fromJson(const {'versionCode': '7'});
    expect(manifest.versionCode, 7);
    expect(manifest.modelName, isEmpty);
    expect(manifest.filename, isEmpty);
    expect(manifest.sha256, isEmpty);
    expect(manifest.sizeBytes, 0);
    expect(manifest.notes, isEmpty);
  });

  test('house constants: stable name/filename match the shipped model', () {
    expect(kBrainModelName, 'gemma-4-E2B-it');
    expect(kBrainModelFileName, 'gemma-4-E2B-it.litertlm');
    expect(kBrainModelAdoptedVersionCode, 1);
  });
}
