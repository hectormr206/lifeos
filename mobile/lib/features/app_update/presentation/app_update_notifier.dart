import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import '../data/apk_download_service.dart';
import '../domain/apk_installer.dart';
import '../domain/app_update_preferences.dart';
import '../domain/update_notification_policy.dart';
import '../domain/update_status.dart';
import 'app_update_providers.dart';

/// UI state for the app-update feature (self-hosted OTA update).
class AppUpdateUiState {
  const AppUpdateUiState({
    this.status = const UpdateUnknown(),
    this.settings = const AppUpdateSettings(),
    this.currentVersionName = '',
    this.currentVersionCode = 0,
    this.checking = false,
    this.downloadProgress,
    this.downloadedApkPath,
    this.installHintNeeded = false,
    this.error,
  });

  /// Latest known update-check result.
  final UpdateStatus status;

  /// Persisted preferences (auto-check / notify / auto-download).
  final AppUpdateSettings settings;

  /// The running build's version name (for the "instalada" line).
  final String currentVersionName;
  final int currentVersionCode;

  /// A check is in flight.
  final bool checking;

  /// Download progress `0.0..1.0`, or null when not downloading.
  final double? downloadProgress;

  /// Absolute path of a downloaded+verified APK ready to install, or null.
  final String? downloadedApkPath;

  /// The user must enable "install unknown apps" before the installer can run.
  final bool installHintNeeded;

  /// A user-facing error (download/verify/install failure), or null.
  final String? error;

  bool get updateAvailable => status is UpdateAvailable;

  AppUpdateUiState copyWith({
    UpdateStatus? status,
    AppUpdateSettings? settings,
    String? currentVersionName,
    int? currentVersionCode,
    bool? checking,
    double? downloadProgress,
    bool clearDownloadProgress = false,
    String? downloadedApkPath,
    bool clearDownloadedApkPath = false,
    bool? installHintNeeded,
    String? error,
    bool clearError = false,
  }) =>
      AppUpdateUiState(
        status: status ?? this.status,
        settings: settings ?? this.settings,
        currentVersionName: currentVersionName ?? this.currentVersionName,
        currentVersionCode: currentVersionCode ?? this.currentVersionCode,
        checking: checking ?? this.checking,
        downloadProgress:
            clearDownloadProgress ? null : (downloadProgress ?? this.downloadProgress),
        downloadedApkPath:
            clearDownloadedApkPath ? null : (downloadedApkPath ?? this.downloadedApkPath),
        installHintNeeded: installHintNeeded ?? this.installHintNeeded,
        error: clearError ? null : (error ?? this.error),
      );
}

final appUpdateNotifierProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateUiState>(AppUpdateNotifier.new);

/// Drives the app-update lifecycle: check → (optionally auto-)download → verify
/// → install. Defensive throughout — a check never throws; download/install
/// failures land in [AppUpdateUiState.error] rather than crashing.
class AppUpdateNotifier extends Notifier<AppUpdateUiState> {
  @override
  AppUpdateUiState build() {
    final seed = ref.read(appUpdateInitialStatusProvider);
    _hydrate();
    return AppUpdateUiState(status: seed ?? const UpdateUnknown());
  }

  Future<void> _hydrate() async {
    try {
      final settings = await ref.read(appUpdatePreferencesProvider).load();
      final version = ref.read(appVersionInfoProvider);
      final name = await version.versionName();
      final code = await version.buildNumber();
      state = state.copyWith(
        settings: settings,
        currentVersionName: name,
        currentVersionCode: code,
      );
    } catch (_) {
      // No platform channel in a widget test / first launch — keep defaults.
    }
  }

  /// Auto-check entry point used on launch: only runs when the user's
  /// auto-check preference is on.
  Future<void> maybeAutoCheck() async {
    final settings = await _safeLoadSettings();
    if (!settings.autoCheck) return;
    await check(auto: true);
  }

  /// Run an update check. [auto] distinguishes a launch/background check from
  /// an explicit "Buscar actualizaciones" tap (both behave the same; the flag
  /// is available for future telemetry).
  Future<void> check({bool auto = false}) async {
    // Load the current preferences up front so the notify/auto-download
    // decisions below never race a still-pending launch-time hydration.
    final settings = await _safeLoadSettings();
    state = state.copyWith(settings: settings, checking: true, clearError: true);
    final result = await ref.read(appUpdateServiceProvider).checkForUpdate();
    state = state.copyWith(status: result, checking: false);

    if (result is! UpdateAvailable) return;

    await _maybeNotify(result);
    if (state.settings.autoDownload) {
      await downloadUpdate();
    }
  }

  Future<void> _maybeNotify(UpdateAvailable available) async {
    if (!state.settings.notify) return;
    try {
      final prefs = ref.read(appUpdatePreferencesProvider);
      final lastCode = await prefs.lastNotifiedVersionCode();
      final lastDay = await prefs.lastNotifiedDay();
      final now = DateTime.now();
      if (!shouldNotifyForUpdate(
        versionCode: available.versionCode,
        now: now,
        lastNotifiedVersionCode: lastCode,
        lastNotifiedDay: lastDay,
      )) {
        return;
      }
      await ref.read(updateNotificationsProvider).showUpdateAvailable(available.versionName);
      await prefs.recordNotified(available.versionCode, dayKey(now));
    } catch (_) {
      // Notification best-effort; the banner still surfaces the update.
    }
  }

  /// Download + verify the available APK, tracking progress in state.
  Future<void> downloadUpdate() async {
    final status = state.status;
    if (status is! UpdateAvailable) return;
    state = state.copyWith(
      downloadProgress: 0,
      clearDownloadedApkPath: true,
      clearError: true,
    );
    try {
      final path = await ref.read(apkDownloadServiceProvider).downloadAndVerify(
            status.manifest,
            onProgress: (p) => state = state.copyWith(downloadProgress: p),
          );
      state = state.copyWith(
        downloadedApkPath: path,
        downloadProgress: 1,
      );
    } on ApkDownloadException catch (e) {
      state = state.copyWith(error: e.message, clearDownloadProgress: true);
    } catch (_) {
      state = state.copyWith(
        error: 'No se pudo descargar la actualización.',
        clearDownloadProgress: true,
      );
    }
  }

  /// Launch the system package installer on the downloaded APK. If "install
  /// unknown apps" is denied, flip [AppUpdateUiState.installHintNeeded] so the
  /// UI can guide the user to enable it (rather than silently failing).
  Future<void> installUpdate() async {
    final path = state.downloadedApkPath;
    if (path == null) return;
    final installer = ref.read(apkInstallerProvider);
    final outcome = await installer.install(path);
    switch (outcome) {
      case InstallOutcome.launched:
        state = state.copyWith(installHintNeeded: false, clearError: true);
      case InstallOutcome.unknownSourcesDenied:
        state = state.copyWith(installHintNeeded: true);
      case InstallOutcome.fileNotFound:
        state = state.copyWith(
          error: 'El archivo descargado ya no está disponible.',
          clearDownloadedApkPath: true,
        );
      case InstallOutcome.failed:
        state = state.copyWith(error: 'No se pudo abrir el instalador.');
    }
  }

  /// Open the OS "install unknown apps" screen so the user can grant it.
  Future<void> openInstallSettings() async {
    await ref.read(apkInstallerProvider).openInstallSettings();
  }

  Future<void> setAutoCheck(bool value) async {
    state = state.copyWith(settings: state.settings.copyWith(autoCheck: value));
    await _persist((p) => p.setAutoCheck(value));
  }

  Future<void> setNotify(bool value) async {
    state = state.copyWith(settings: state.settings.copyWith(notify: value));
    await _persist((p) => p.setNotify(value));
  }

  Future<void> setAutoDownload(bool value) async {
    state = state.copyWith(settings: state.settings.copyWith(autoDownload: value));
    await _persist((p) => p.setAutoDownload(value));
  }

  Future<AppUpdateSettings> _safeLoadSettings() async {
    try {
      return await ref.read(appUpdatePreferencesProvider).load();
    } catch (_) {
      return state.settings;
    }
  }

  Future<void> _persist(Future<void> Function(AppUpdatePreferences) op) async {
    try {
      await op(ref.read(appUpdatePreferencesProvider));
    } catch (_) {
      // Best-effort persistence; in-memory state already reflects the choice.
    }
  }
}

/// Watched once by the root widget so a launch-time auto-check fires as soon
/// as the device is (or becomes) paired — mirrors `outboxSyncTriggerProvider`.
final appUpdateLaunchCheckProvider = Provider<void>((ref) {
  final connection = ref.watch(connectionNotifierProvider);
  if (connection is ConnectionPaired) {
    Future.microtask(() => ref.read(appUpdateNotifierProvider.notifier).maybeAutoCheck());
  }
});
