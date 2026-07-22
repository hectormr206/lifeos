import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.installPending = false,
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

  /// An update flow is in progress and the installer still needs to fire once
  /// the APK is ready (and the "install unknown apps" grant is present). Kept
  /// so a resume — e.g. after the user grants the permission in OS settings —
  /// can auto-continue the install without a second manual tap.
  final bool installPending;

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
    bool? installPending,
    bool clearInstallPending = false,
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
        installPending: clearInstallPending ? false : (installPending ?? this.installPending),
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
    if (state.checking) return;
    final settings = await _safeLoadSettings();
    if (!settings.autoCheck) return;
    await check(auto: true);
  }

  /// Called when the app returns to the foreground (from the root
  /// [WidgetsBindingObserver]). Two jobs, in order:
  ///  1. If an install was left pending because "install unknown apps" was off,
  ///     re-check the grant and auto-continue the install now that the user may
  ///     have enabled it — no second manual tap (fixes the grant dead-end).
  ///  2. Re-run the update check so an update published while the app was open
  ///     is detected on resume, not only on a cold start.
  Future<void> onAppResumed() async {
    await _resumeInstallIfPending();
    await maybeAutoCheck();
  }

  Future<void> _resumeInstallIfPending() async {
    if (!state.installPending || state.downloadedApkPath == null) return;
    final installer = ref.read(apkInstallerProvider);
    bool granted;
    try {
      granted = await installer.canInstallPackages();
    } catch (_) {
      granted = false;
    }
    if (!granted) return;
    state = state.copyWith(installHintNeeded: false);
    await _tryInstall();
  }

  /// One-tap update entry point (the target flow). Downloads + verifies the
  /// APK with visible progress, then launches the system installer. If the
  /// "install unknown apps" grant is missing it requests it and leaves the flow
  /// pending so [onAppResumed] auto-continues once the user grants it.
  Future<void> startUpdate() async {
    final status = state.status;
    if (status is! UpdateAvailable) return;
    state = state.copyWith(installPending: true, clearError: true);
    // Download first unless a verified APK is already on disk; progress is
    // surfaced the whole time via [downloadUpdate].
    if (state.downloadedApkPath == null) {
      await downloadUpdate();
      if (state.downloadedApkPath == null) return; // download failed → error set
    }
    await _tryInstall();
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

  /// Manual/retry entry point for the "Instalar ahora" button — fires the
  /// installer on the already-downloaded APK.
  Future<void> installUpdate() => _tryInstall();

  /// Launch the system package installer on the downloaded APK. If "install
  /// unknown apps" is denied, request the grant and keep the flow pending
  /// ([installHintNeeded] guides the UI meanwhile) so [onAppResumed] can
  /// auto-continue once it is granted — rather than silently failing or
  /// forcing a second manual tap.
  Future<void> _tryInstall() async {
    final path = state.downloadedApkPath;
    if (path == null) return;
    final installer = ref.read(apkInstallerProvider);
    if (!await installer.canInstallPackages()) {
      state = state.copyWith(installHintNeeded: true, installPending: true);
      // Opens the OS "install unknown apps" toggle; backgrounds the app. The
      // resume path re-checks the grant and continues automatically.
      await installer.requestInstallPermission();
      return;
    }
    final outcome = await installer.install(path);
    switch (outcome) {
      case InstallOutcome.launched:
        state = state.copyWith(
          installHintNeeded: false,
          clearInstallPending: true,
          clearError: true,
        );
      case InstallOutcome.unknownSourcesDenied:
        state = state.copyWith(installHintNeeded: true, installPending: true);
        await installer.requestInstallPermission();
      case InstallOutcome.fileNotFound:
        state = state.copyWith(
          error: 'El archivo descargado ya no está disponible.',
          clearDownloadedApkPath: true,
          clearInstallPending: true,
        );
      case InstallOutcome.failed:
        state = state.copyWith(
          error: 'No se pudo abrir el instalador.',
          clearInstallPending: true,
        );
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

/// Watched once by the root widget so a launch-time auto-check fires on
/// startup. The update source is now a PUBLIC URL (not the paired engine), so
/// this runs regardless of pairing — `maybeAutoCheck` still honors the user's
/// auto-check preference.
final appUpdateLaunchCheckProvider = Provider<void>((ref) {
  Future.microtask(() => ref.read(appUpdateNotifierProvider.notifier).maybeAutoCheck());
});
