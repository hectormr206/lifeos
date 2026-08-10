import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../../../core/tray/tray_platform.dart' show runningUnderFlutterTest;
import '../data/apk_download_service.dart';
import '../data/app_update_service.dart';
import '../domain/apk_installer.dart';
import '../domain/app_restarter.dart';
import '../domain/desktop_update_trigger.dart';
import '../domain/desktop_update_watcher.dart';
import '../domain/app_update_preferences.dart';
import '../domain/app_version_info.dart';
import '../domain/installed_release.dart';
import '../domain/update_notifications.dart';
import '../domain/update_source_config.dart';
import '../domain/update_status.dart';

/// The version identity `package_info_plus` reports, straight out of the app
/// bundle. THE ANDROID SOURCE — see [appVersionInfoProvider] for why desktop
/// does not use it. Overridden with a fake in tests.
final packageAppVersionInfoProvider =
    Provider<AppVersionInfo>((ref) => const PackageInfoAppVersion());

/// The running build's version identity, from the source that is TRUE on this
/// platform. Overridden with a fake in tests.
///
/// PLATFORM-DEPENDENT SOURCE, SHARED BEHAVIOUR. Everything downstream — the
/// version comparison in `AppUpdateService`, the Updates screen, the Home
/// banner — is one implementation for every OS. The only thing that forks is
/// where the running build number comes from, because on the desktop the app
/// bundle simply does not carry it: the Flutter Linux build writes pubspec's
/// `+1` into `flutter_assets/version.json` and ignores `--build-number`, so
/// `package_info_plus` reported build 1 on a machine running release 795 and
/// the app offered an update the user had already installed. The installer's
/// own `/opt/lifeos/manifest.json` is the record that tracks what is really
/// there, and [installedReleaseReaderProvider] already reads it.
final appVersionInfoProvider = Provider<AppVersionInfo>((ref) {
  if (isDesktopPlatform(ref.watch(hostOperatingSystemProvider))) {
    return InstalledReleaseAppVersion(ref.watch(installedReleaseReaderProvider));
  }
  return ref.watch(packageAppVersionInfoProvider);
});

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

/// What is really installed in `/opt/lifeos` right now. Read BEFORE a desktop
/// update is requested and polled after, so the app reports what happened
/// instead of what it asked for. Faked in tests.
final installedReleaseReaderProvider = Provider<InstalledReleaseReader>(
    (ref) => const OptLifeosInstalledReleaseReader());

/// Watches for the outcome of a requested desktop update.
///
/// Built from the two ports above rather than overridden wholesale in
/// production; tests override this one provider to return a scripted outcome
/// without a disk, a systemd or a five-minute wait.
final desktopUpdateWatcherProvider = Provider<DesktopUpdateWatcher>(
  (ref) => PollingDesktopUpdateWatcher(
    reader: ref.watch(installedReleaseReaderProvider),
    trigger: ref.watch(desktopUpdateTriggerProvider),
  ),
);

/// Relaunches LifeOS into the version that was just installed, or `null` where
/// that is not a thing this platform allows.
///
/// Null on the phones (the OS owns app lifecycle there — killing our own
/// process would be a crash, not a restart) and null under `flutter test`,
/// which runs on a real Linux box: without that guard a suite that exercised
/// the applied-update path would spawn `/opt/lifeos/current/bundle/lifeos` on
/// the machine running the tests and then call `exit(0)` on the test runner.
/// A test that wants the behaviour injects a fake, exactly as the tray and
/// login-autostart ports do.
final appRestarterProvider = Provider<AppRestarter?>((ref) {
  if (!isDesktopPlatform(ref.watch(hostOperatingSystemProvider))) return null;
  if (runningUnderFlutterTest()) return null;
  return const DetachedProcessAppRestarter();
});

/// How long the "Reiniciando LifeOS…" state stays on screen before the process
/// really goes. Not cosmetic padding: without it the window vanishes with no
/// explanation, which reads as a crash rather than as the restart the user
/// asked for. Overridden to zero in tests.
final desktopRestartGraceProvider =
    Provider<Duration>((ref) => const Duration(milliseconds: 900));

/// Test seam: an initial [UpdateStatus] the notifier starts from (default
/// null → `UpdateUnknown`). Lets widget tests render a specific state (e.g.
/// [UpdateAvailable]) without driving a real network check. Never overridden
/// in production.
final appUpdateInitialStatusProvider = Provider<UpdateStatus?>((ref) => null);
