import 'package:lifeos/features/app_update/domain/apk_installer.dart';
import 'package:lifeos/features/app_update/domain/app_update_preferences.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/domain/update_notifications.dart';

/// In-memory [AppVersionInfo] — no `package_info_plus` platform channel.
class FakeAppVersionInfo implements AppVersionInfo {
  FakeAppVersionInfo({this.code = 10, this.name = '1.0.0'});
  int code;
  String name;
  @override
  Future<int> buildNumber() async => code;
  @override
  Future<String> versionName() async => name;
}

/// In-memory [AppUpdatePreferences] — no shared_preferences channel.
class FakeAppUpdatePreferences implements AppUpdatePreferences {
  FakeAppUpdatePreferences({AppUpdateSettings? initial}) : _settings = initial ?? const AppUpdateSettings();
  AppUpdateSettings _settings;
  int? notifiedCode;
  String? notifiedDay;
  int recordNotifiedCalls = 0;

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
}

/// Records "showUpdateAvailable" calls.
class FakeUpdateNotifications implements UpdateNotifications {
  final List<String> shown = [];
  @override
  Future<void> showUpdateAvailable(String versionName) async => shown.add(versionName);
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
