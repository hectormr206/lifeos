import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../data/apk_download_service.dart';
import '../data/app_update_service.dart';
import '../domain/apk_installer.dart';
import '../domain/app_update_preferences.dart';
import '../domain/app_version_info.dart';
import '../domain/update_notifications.dart';
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

/// Update-check service — reuses the shared authenticated [dioProvider] Dio,
/// so `GET /api/app/manifest` carries the pairing bearer token automatically.
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(ref.watch(dioProvider), ref.watch(appVersionInfoProvider));
});

/// APK download + sha256 verification service (background_downloader + the
/// stored bearer token). Faked in tests.
final apkDownloadServiceProvider = Provider<ApkDownloadService>((ref) {
  return ApkDownloadService(ref.watch(tokenStoreProvider));
});

/// Test seam: an initial [UpdateStatus] the notifier starts from (default
/// null → `UpdateUnknown`). Lets widget tests render a specific state (e.g.
/// [UpdateAvailable]) without driving a real network check. Never overridden
/// in production.
final appUpdateInitialStatusProvider = Provider<UpdateStatus?>((ref) => null);
