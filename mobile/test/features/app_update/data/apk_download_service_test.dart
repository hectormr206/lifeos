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

/// Scriptable [FileDownloader] surface for the attach/resume logic — no
/// platform channel. [known] seeds `allTasks` (active AND paused tasks, like
/// the real merge); [resumable] controls which taskIds `resumeAll` accepts;
/// [dropKnownAfterResumeAll] mimics the real `resume()` clearing a paused
/// record even when the resume FAILS (no resume data).
class _FakeFileDownloader extends Fake implements FileDownloader {
  _FakeFileDownloader({
    required List<String> known,
    required this.resumable,
    this.dropKnownAfterResumeAll = false,
  }) : _known = List.of(known);

  final List<String> _known;
  final List<String> resumable;
  final bool dropKnownAfterResumeAll;

  int resumeAllCalls = 0;
  final List<DownloadTask> enqueued = [];
  final List<String> cancelledIds = [];

  DownloadTask _task(String id) => DownloadTask(
        taskId: id,
        url: 'https://updates.example/lifeos/download',
        group: 'app_updates',
      );

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async =>
      [for (final id in _known) _task(id)];

  @override
  Future<List<Task>> resumeAll({
    Iterable<DownloadTask>? tasks,
    String? group,
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    resumeAllCalls++;
    final resumed = [for (final id in _known.where(resumable.contains)) _task(id)];
    if (dropKnownAfterResumeAll) _known.clear();
    return resumed;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async {
    cancelledIds.add(taskId);
    _known.remove(taskId);
    return true;
  }

  @override
  Future<bool> enqueue(Task task) async {
    enqueued.add(task as DownloadTask);
    _known.add(task.taskId);
    return true;
  }
}

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

  group('attach / resume (paused tasks are never a silent dead-end)', () {
    test('attaching to a PAUSED task RESUMES it (returns false, no re-enqueue)', () async {
      final downloader = _FakeFileDownloader(
        known: ['app_update_apk'],
        resumable: ['app_update_apk'],
      );
      final svc = ApkDownloadService(config: _configured, downloader: downloader);

      final started = await svc.startDownload(_manifest);

      expect(started, isFalse, reason: 'attached, not restarted');
      expect(downloader.resumeAllCalls, 1, reason: 'the paused task was kicked');
      expect(downloader.enqueued, isEmpty);
      expect(downloader.cancelledIds, isEmpty);
    });

    test('a paused ORPHAN that refuses to resume is cancelled + re-enqueued', () async {
      // Simulates the orphaned paused record: known to allTasks once, but
      // resume fails (no resume data) and the failed attempt drops the record.
      final downloader = _FakeFileDownloader(
        known: ['app_update_apk'],
        resumable: const [],
        dropKnownAfterResumeAll: true,
      );
      final svc = ApkDownloadService(config: _configured, downloader: downloader);

      final started = await svc.startDownload(_manifest);

      expect(started, isTrue, reason: 'a fresh task replaces the dead record');
      expect(downloader.cancelledIds, ['app_update_apk']);
      expect(downloader.enqueued.single.taskId, 'app_update_apk');
    });

    test('a genuinely RUNNING task is left untouched (attach only)', () async {
      final downloader = _FakeFileDownloader(
        known: ['app_update_apk'],
        resumable: const [], // resumeAll touches only paused tasks → no-op
      );
      final svc = ApkDownloadService(config: _configured, downloader: downloader);

      final started = await svc.startDownload(_manifest);

      expect(started, isFalse);
      expect(downloader.enqueued, isEmpty, reason: 'never restart from zero');
      expect(downloader.cancelledIds, isEmpty);
    });

    test('no existing task → fresh enqueue', () async {
      final downloader = _FakeFileDownloader(known: const [], resumable: const []);
      final svc = ApkDownloadService(config: _configured, downloader: downloader);

      final started = await svc.startDownload(_manifest);

      expect(started, isTrue);
      expect(downloader.enqueued.single.taskId, 'app_update_apk');
      expect(downloader.resumeAllCalls, 0);
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
