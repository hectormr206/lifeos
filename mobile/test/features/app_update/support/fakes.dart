import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:lifeos/features/app_update/data/apk_download_service.dart';
import 'package:lifeos/features/app_update/domain/apk_installer.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/app_update_preferences.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';
import 'package:lifeos/features/app_update/domain/update_notifications.dart';

/// In-memory [AppVersionInfo] — no `package_info_plus` platform channel.
///
/// [code] is nullable because "unknown" is a real answer this port has to be
/// able to give: on the desktop the installed build number comes off disk and
/// the disk may have nothing to say (see [FakeInstalledReleaseReader]).
class FakeAppVersionInfo implements AppVersionInfo {
  FakeAppVersionInfo({this.code = 10, this.name = '1.0.0'});
  int? code;
  String name;
  @override
  Future<int?> buildNumber() async => code;
  @override
  Future<String> versionName() async => name;
}

/// In-memory [InstalledReleaseReader] — no `/opt/lifeos` on the test machine.
/// `null` stands for "the installer left nothing readable here".
class FakeInstalledReleaseReader implements InstalledReleaseReader {
  FakeInstalledReleaseReader(this.release);
  InstalledRelease? release;
  @override
  Future<InstalledRelease?> read() async => release;
}

/// In-memory [AppUpdatePreferences] — no shared_preferences channel.
class FakeAppUpdatePreferences implements AppUpdatePreferences {
  FakeAppUpdatePreferences({AppUpdateSettings? initial}) : _settings = initial ?? const AppUpdateSettings();
  AppUpdateSettings _settings;
  int? notifiedCode;
  String? notifiedDay;
  int recordNotifiedCalls = 0;

  /// Banner snooze, kept as a VERSION + a calendar day (never a bare boolean)
  /// so "a newer build re-shows it" is expressible at all.
  int? dismissedCode;
  String? dismissedDayValue;

  @override
  Future<AppUpdateSettings> load() async => _settings;
  @override
  Future<void> setAutoCheck(bool value) async => _settings = _settings.copyWith(autoCheck: value);
  @override
  Future<void> setNotify(bool value) async => _settings = _settings.copyWith(notify: value);
  @override
  Future<void> setAutoDownload(bool value) async =>
      _settings = _settings.copyWith(autoDownload: value);
  @override
  Future<int?> lastNotifiedVersionCode() async => notifiedCode;
  @override
  Future<String?> lastNotifiedDay() async => notifiedDay;
  @override
  Future<void> recordNotified(int versionCode, String day) async {
    recordNotifiedCalls++;
    notifiedCode = versionCode;
    notifiedDay = day;
  }

  @override
  Future<int?> dismissedBannerVersionCode() async => dismissedCode;
  @override
  Future<String?> dismissedBannerDay() async => dismissedDayValue;
  @override
  Future<void> recordBannerDismissed(int versionCode, String day) async {
    dismissedCode = versionCode;
    dismissedDayValue = day;
  }
}

/// Records "showUpdateAvailable" + "showUpdateReady" calls.
class FakeUpdateNotifications implements UpdateNotifications {
  final List<String> shown = [];
  final List<String> readyShown = [];
  void Function()? tapHandler;
  bool launchedByTapResult = false;

  @override
  Future<void> showUpdateAvailable(String versionName) async => shown.add(versionName);
  @override
  Future<void> showUpdateReady(String versionName) async => readyShown.add(versionName);
  @override
  Future<void> registerTapHandler(void Function() onTapUpdate) async => tapHandler = onTapUpdate;
  @override
  Future<bool> launchedByTap() async => launchedByTapResult;
}

/// Scriptable [ApkInstaller].
class FakeApkInstaller implements ApkInstaller {
  FakeApkInstaller({this.outcome = InstallOutcome.launched, this.canInstall = true});
  InstallOutcome outcome;
  bool canInstall;
  int installCalls = 0;
  int openSettingsCalls = 0;
  String? installedPath;

  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<bool> requestInstallPermission() async => canInstall;
  @override
  Future<InstallOutcome> install(String apkPath) async {
    installCalls++;
    installedPath = apkPath;
    return outcome;
  }

  @override
  Future<void> openInstallSettings() async => openSettingsCalls++;
}

/// In-memory [ApkDownloadService] with a controllable updates stream — no
/// `background_downloader` platform channel. Drives the notifier's app-level
/// listener from tests: push [emitProgress]/[emitComplete]/[emitFailed] events
/// and assert how state reacts. Records how many times a download was started
/// and whether it "attached" (already running) vs. enqueued fresh.
class FakeApkDownloadService extends ApkDownloadService {
  FakeApkDownloadService() : super();

  final StreamController<TaskUpdate> _controller = StreamController<TaskUpdate>.broadcast();

  int startCalls = 0;

  /// When true, [startDownload] reports it attached to an in-flight task
  /// (returns false) instead of enqueuing a new one.
  bool alreadyRunning = false;

  /// Path [apkFilePath] resolves and [verifyApk] receives.
  String apkPath = '/tmp/lifeos-update.apk';

  /// When true, [verifyApk] throws (sha256 mismatch simulation).
  bool verifyThrows = false;
  String? verifiedPath;

  DownloadTask get _task => DownloadTask(
        taskId: 'app_update_apk',
        url: 'https://updates.example/lifeos/download',
        group: 'app_updates',
      );

  @override
  Stream<TaskUpdate> get updates => _controller.stream;

  @override
  bool isUpdateTask(Task task) => task.group == 'app_updates';

  @override
  Future<bool> startDownload(AppManifest manifest) async {
    startCalls++;
    return !alreadyRunning;
  }

  @override
  Future<String> apkFilePath(AppManifest manifest) async => apkPath;

  @override
  Future<void> verifyApk(String path, String expectedSha256) async {
    verifiedPath = path;
    if (verifyThrows) throw ApkDownloadException('sha256 mismatch');
  }

  void emitProgress(double p) => _controller.add(TaskProgressUpdate(_task, p));
  void emitComplete() => _controller.add(TaskStatusUpdate(_task, TaskStatus.complete));
  void emitStatus(TaskStatus s) => _controller.add(TaskStatusUpdate(_task, s));

  Future<void> dispose() => _controller.close();
}
