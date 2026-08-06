import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/apk_download_service.dart';
import '../data/app_update_service.dart';
import '../domain/apk_installer.dart';
import '../domain/desktop_update_trigger.dart';
import '../domain/app_update_preferences.dart';
import '../domain/app_version_info.dart';
import '../domain/update_notifications.dart';
import '../domain/update_source_config.dart';
import '../domain/update_status.dart';

/// The running build's version identity. Overridden with a fake in tests.
final appVersionInfoProvider = Provider<AppVersionInfo>((ref) => const PackageInfoAppVersion());

/// Local-only app-update preferences (shared_preferences). Faked in tests.
final appUpdatePreferencesProvider =
    Provider<AppUpdatePreferences>((ref) => SharedPrefsAppUpdatePreferences());

/// Local "update available" notifications. Faked in tests.
final updateNotificationsProvider =
    Provider<UpdateNotifications>((ref) => FlutterLocalUpdateNotifications());

/// Hands a downloaded APK to the Android package installer. Faked in tests.
final apkInstallerProvider = Provider<ApkInstaller>((ref) => const OpenFilexApkInstaller());

/// The public update source (base URL + bundled access key). Built from the
/// compile-time config (`--dart-define` overrides, else the placeholders in
/// `update_source_config.dart`). Overridable in tests.
final updateSourceConfigProvider =
    Provider<UpdateSourceConfig>((ref) => const UpdateSourceConfig.fromEnvironment());

/// Update-check service — uses a PLAIN Dio pointed at the PUBLIC update source
/// (NOT the paired `dioProvider`), sending the bundled access key as the
/// `X-LifeOS-Update-Key` header. No pairing, no bearer token.
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final config = ref.watch(updateSourceConfigProvider);
  final dio = Dio(BaseOptions(baseUrl: config.baseUrl));
  return AppUpdateService(dio, ref.watch(appVersionInfoProvider), config: config);
});

/// APK download + sha256 verification service — downloads from the PUBLIC
/// update source with the `X-LifeOS-Update-Key` header (no stored bearer
/// token). Faked in tests.
final apkDownloadServiceProvider = Provider<ApkDownloadService>((ref) {
  return ApkDownloadService(config: ref.watch(updateSourceConfigProvider));
});

/// Asks systemd to perform the desktop update. On Android this is never read
/// (the APK installer path applies instead). Faked in tests.
final desktopUpdateTriggerProvider =
    Provider<DesktopUpdateTrigger>((ref) => const SystemdPathUpdateTrigger());

/// Test seam: an initial [UpdateStatus] the notifier starts from (default
/// null → `UpdateUnknown`). Lets widget tests render a specific state (e.g.
/// [UpdateAvailable]) without driving a real network check. Never overridden
/// in production.
final appUpdateInitialStatusProvider = Provider<UpdateStatus?>((ref) => null);
