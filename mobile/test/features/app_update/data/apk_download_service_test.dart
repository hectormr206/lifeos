// Proves the download service now targets the PUBLIC update source:
//  * the DownloadTask points at <base>/download and carries the bundled
//    X-LifeOS-Update-Key header (no pairing/bearer token anymore), and
//  * the sha256 verification gate still holds — a matching hash passes; a
//    mismatch throws ApkDownloadException AND deletes the rejected file so it
//    can never reach the installer.
// Operates on real temp files (crypto is deterministic) — the
// background_downloader network step is not exercised here.
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/data/apk_download_service.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';

const _configured = UpdateSourceConfig(
  baseUrl: 'https://updates.example/lifeos',
  accessKey: 'test-key-123',
);

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 150000000,
  notes: '',
  publishedAt: '',
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_verify_test');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ApkDownloadService service() => ApkDownloadService(config: _configured);

  group('download task (public source)', () {
    test('targets <base>/download with the X-LifeOS-Update-Key header', () {
      final DownloadTask task = service().buildDownloadTask(_manifest);
      expect(task.url, 'https://updates.example/lifeos/download');
      expect(task.headers[kUpdateAccessKeyHeader], 'test-key-123');
      expect(task.headers.containsKey('Authorization'), isFalse,
          reason: 'public source uses the access key, not a bearer token');
    });

    test('trims a trailing slash on the base URL', () {
      final svc = ApkDownloadService(
        config: const UpdateSourceConfig(baseUrl: 'https://u.example/lifeos/', accessKey: 'k'),
      );
      expect(svc.buildDownloadTask(_manifest).url, 'https://u.example/lifeos/download');
    });

    test('uses a STABLE task id + allowPause so re-entry attaches and resumes', () {
      final task = service().buildDownloadTask(_manifest);
      // Fixed id → a second start finds (attaches to) the same task instead of
      // spawning a random-id duplicate.
      expect(task.taskId, 'app_update_apk');
      expect(service().buildDownloadTask(_manifest).taskId, task.taskId);
      // Resumable: an interrupted transfer resumes rather than restarting.
      expect(task.allowPause, isTrue);
      expect(service().isUpdateTask(task), isTrue);
    });
  });

  group('sha256 verification gate', () {
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
  });
}
