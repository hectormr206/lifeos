// Proves the sha256 verification gate: a downloaded file whose hash matches
// the manifest passes; a mismatch throws ApkDownloadException AND deletes the
// rejected file so it can never reach the installer. Operates on real temp
// files (crypto is deterministic) — the background_downloader network step is
// not exercised here.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/app_update/data/apk_download_service.dart';

class _NullTokenStore implements TokenStore {
  @override
  Future<StoredConnection?> load() async => null;
  @override
  Future<void> save(StoredConnection connection) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_verify_test');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ApkDownloadService service() => ApkDownloadService(_NullTokenStore());

  test('passes when the file sha256 matches the manifest', () async {
    final file = File('${tmp.path}/app.apk');
    final bytes = List<int>.generate(2048, (i) => i % 256);
    await file.writeAsBytes(bytes);
    final expected = sha256.convert(bytes).toString();

    await service().verifyApk(file.path, expected);
    expect(file.existsSync(), isTrue);
  });

  test('accepts an uppercase expected hash (case-insensitive)', () async {
    final file = File('${tmp.path}/app.apk');
    final bytes = [1, 2, 3, 4, 5];
    await file.writeAsBytes(bytes);
    final expected = sha256.convert(bytes).toString().toUpperCase();

    await service().verifyApk(file.path, expected);
    expect(file.existsSync(), isTrue);
  });

  test('rejects and deletes the file on a sha256 mismatch', () async {
    final file = File('${tmp.path}/app.apk');
    await file.writeAsBytes([9, 9, 9, 9]);

    await expectLater(
      service().verifyApk(file.path, 'deadbeef'),
      throwsA(isA<ApkDownloadException>()),
    );
    expect(file.existsSync(), isFalse, reason: 'rejected APK must be deleted');
  });

  test('throws when the file cannot be read', () async {
    await expectLater(
      service().verifyApk('${tmp.path}/does-not-exist.apk', 'abc'),
      throwsA(isA<ApkDownloadException>()),
    );
  });
}
