import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/app_manifest.dart';
import '../domain/update_source_config.dart';

/// Raised when a downloaded APK fails verification and must be rejected.
class ApkDownloadException implements Exception {
  ApkDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the published APK from the PUBLIC update source
/// (`GET <base>/download`) and verifies it before it is ever handed to the
/// installer (self-hosted OTA update, WITHOUT pairing).
///
/// The download goes through `background_downloader` (already a dependency)
/// rather than Dio so it survives backgrounding and posts a progress
/// notification. Formerly it attached the pairing Bearer token from the
/// [TokenStore]; it now attaches only the bundled access key as the
/// [kUpdateAccessKeyHeader] header, so no pairing is required. After the bytes
/// land, the file's SHA-256 is checked against the manifest; a mismatch
/// deletes the file and throws, so a corrupt/tampered APK can never reach the
/// package installer.
class ApkDownloadService {
  ApkDownloadService({
    this._config = const UpdateSourceConfig.fromEnvironment(),
    FileDownloader? downloader,
  }) : _downloader = downloader ?? FileDownloader();

  final UpdateSourceConfig _config;
  final FileDownloader _downloader;

  static const String _group = 'app_updates';
  static const String _filename = 'lifeos-update.apk';

  /// Fixed task id so a re-entry into the flow ATTACHES to the same background
  /// task instead of spawning a second one. (Without a stable id every
  /// [DownloadTask] gets a random id and the "is it already running?" check
  /// below could never match.)
  static const String _taskId = 'app_update_apk';

  /// Broadcast stream of task updates (status + progress) coming from the
  /// native background isolate. The app-level listener in
  /// [AppUpdateNotifier] subscribes to this ONCE so progress and completion are
  /// tracked independently of whichever screen is (or isn't) on top — the
  /// download keeps flowing into state after the Updates screen is gone.
  Stream<TaskUpdate> get updates => _downloader.updates;

  /// Whether [task] is our app-update download (vs. any other group sharing the
  /// same [FileDownloader] singleton, e.g. STT/model/voice downloads). The
  /// listener uses this to ignore unrelated traffic.
  bool isUpdateTask(Task task) => task.group == _group && task.taskId == _taskId;

  /// Build the [DownloadTask] for [manifest]: `<base>/download` with the
  /// access-key header. Exposed for testing the URL + header wiring without
  /// touching the network.
  ///
  /// `allowPause: true` marks the task resumable, so an interrupted/backgrounded
  /// transfer resumes from where it left off (when the server honors range
  /// requests) rather than restarting from zero.
  @visibleForTesting
  DownloadTask buildDownloadTask(AppManifest manifest) => DownloadTask(
        taskId: _taskId,
        url: _joinUrl(_config.baseUrl, '/download'),
        headers: {kUpdateAccessKeyHeader: _config.accessKey},
        filename: _filename,
        group: _group,
        baseDirectory: BaseDirectory.temporary,
        directory: 'app_updates',
        updates: Updates.statusAndProgress,
        allowPause: true,
      );

  /// Start — or ATTACH to — the background download of the APK described by
  /// [manifest]. If a task for the update is already enqueued/running/paused it
  /// is LEFT UNTOUCHED (never reset/cancelled) and this returns `false`; the
  /// shared [updates] listener is already carrying its progress. Otherwise a
  /// fresh task is enqueued and this returns `true`.
  ///
  /// Unlike the old convenience `download(...)` call, this does NOT await the
  /// transfer — progress and completion arrive asynchronously on [updates], so
  /// the download outlives the caller (and the screen).
  Future<bool> startDownload(AppManifest manifest) async {
    if (!_config.isConfigured) {
      throw ApkDownloadException('Origen de actualizaciones no configurado.');
    }
    // Already in flight? Attach — do NOT reset an active/paused task (that was
    // the bug: re-entering the flow cancelled and restarted from zero).
    if (await _isAlreadyRunning()) return false;

    final task = buildDownloadTask(manifest);
    final enqueued = await _downloader.enqueue(task);
    if (!enqueued) {
      throw ApkDownloadException('No se pudo iniciar la descarga.');
    }
    return true;
  }

  /// True when our update task is already known to the native downloader
  /// (enqueued, running, paused, or waiting to retry).
  Future<bool> _isAlreadyRunning() async {
    try {
      final tasks = await _downloader.allTasks(group: _group);
      return tasks.any((t) => t.taskId == _taskId);
    } catch (_) {
      // No platform channel / probe failure — treat as "not running" so a
      // fresh enqueue can proceed rather than wedging the flow.
      return false;
    }
  }

  /// Absolute path the APK lands at (once complete) for verification + install.
  Future<String> apkFilePath(AppManifest manifest) => buildDownloadTask(manifest).filePath();

  /// Verify the file at [path] has SHA-256 == [expectedSha256]. Deletes the
  /// file and throws [ApkDownloadException] on mismatch or a read failure.
  Future<void> verifyApk(String path, String expectedSha256) async {
    final file = File(path);
    final Digest digest;
    try {
      digest = sha256.convert(await file.readAsBytes());
    } catch (_) {
      throw ApkDownloadException('No se pudo leer el archivo descargado.');
    }
    final actual = digest.toString().toLowerCase();
    if (actual != expectedSha256.toLowerCase()) {
      try {
        await file.delete();
      } catch (_) {/* best effort — the mismatch is what matters */}
      throw ApkDownloadException('La verificación SHA-256 falló; descarga descartada.');
    }
  }

  static String _joinUrl(String base, String path) {
    if (base.endsWith('/')) return base.substring(0, base.length - 1) + path;
    return base + path;
  }
}
