import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/apk_download_service.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../domain/apk_installer.dart';
import '../domain/desktop_update_trigger.dart';
import '../domain/app_manifest.dart';
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
    this.downloadedApkKey,
    this.installHintNeeded = false,
    this.installPending = false,
    this.desktopUpdateRequested = false,
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

  /// Identity of the manifest ([AppUpdateNotifier.manifestKey]:
  /// `versionCode:sha256`) the downloaded APK was VERIFIED against. The path is
  /// only ever installed while this matches the CURRENT manifest — a server
  /// republish invalidates the stale file instead of installing it.
  final String? downloadedApkKey;

  /// The user must enable "install unknown apps" before the installer can run.
  final bool installHintNeeded;

  /// An update flow is in progress and the installer still needs to fire once
  /// the APK is ready (and the "install unknown apps" grant is present). Kept
  /// so a resume — e.g. after the user grants the permission in OS settings —
  /// can auto-continue the install without a second manual tap.
  final bool installPending;

  /// The desktop updater has been ASKED to run (the systemd trigger file was
  /// created). Not "the update finished": the updater runs as a separate root
  /// process and replaces this release out from under the running app, so
  /// there is nothing further this process can honestly report.
  final bool desktopUpdateRequested;

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
    String? downloadedApkKey,
    bool? installHintNeeded,
    bool? installPending,
    bool clearInstallPending = false,
    bool? desktopUpdateRequested,
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
        // The key lives and dies with the path: same clear flag, so they can
        // never drift apart.
        downloadedApkKey:
            clearDownloadedApkPath ? null : (downloadedApkKey ?? this.downloadedApkKey),
        installHintNeeded: installHintNeeded ?? this.installHintNeeded,
        installPending: clearInstallPending ? false : (installPending ?? this.installPending),
        desktopUpdateRequested: desktopUpdateRequested ?? this.desktopUpdateRequested,
        error: clearError ? null : (error ?? this.error),
      );
}

final appUpdateNotifierProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateUiState>(AppUpdateNotifier.new);

/// Drives the app-update lifecycle: check → (optionally auto-)download → verify
/// → install. Defensive throughout — a check never throws; download/install
/// failures land in [AppUpdateUiState.error] rather than crashing.
class AppUpdateNotifier extends Notifier<AppUpdateUiState> {
  /// App-level subscription to the background APK download's status+progress
  /// stream. Registered ONCE from [build] (this provider is kept alive for the
  /// app's lifetime) so the download is tracked independently of the Updates
  /// screen — leaving the screen no longer stops or restarts it.
  StreamSubscription<TaskUpdate>? _updatesSub;

  @override
  AppUpdateUiState build() {
    final seed = ref.read(appUpdateInitialStatusProvider);
    _hydrate();
    _listenForDownloadUpdates();
    ref.onDispose(() {
      _updatesSub?.cancel();
      _updatesSub = null;
    });
    return AppUpdateUiState(status: seed ?? const UpdateUnknown());
  }

  /// Subscribe (exactly once) to the download service's updates stream so
  /// background progress/completion flow into state even when no screen is
  /// listening. Guarded against duplicate subscriptions; a missing platform
  /// channel (widget tests without a fake service) is swallowed.
  void _listenForDownloadUpdates() {
    if (_updatesSub != null) return;
    try {
      _updatesSub =
          ref.read(apkDownloadServiceProvider).updates.listen(_onDownloadUpdate);
    } catch (_) {
      // No background_downloader channel in this context — the stream is
      // optional; the flow still works, just without background tracking.
    }
  }

  /// Handle one background-download event. Progress advances the bar;
  /// completion verifies + records the APK and posts the "ready" notification;
  /// a terminal failure surfaces an error. Ignores traffic from other download
  /// groups sharing the same [FileDownloader] singleton.
  Future<void> _onDownloadUpdate(TaskUpdate update) async {
    final service = ref.read(apkDownloadServiceProvider);
    if (!service.isUpdateTask(update.task)) return;

    if (update is TaskProgressUpdate) {
      final p = update.progress;
      // Negative sentinels (e.g. progressFailed) aren't real progress.
      if (p >= 0 && state.downloadedApkPath == null) {
        state = state.copyWith(downloadProgress: p.clamp(0.0, 1.0));
      }
      return;
    }
    if (update is TaskStatusUpdate) {
      switch (update.status) {
        case TaskStatus.complete:
          await _onDownloadComplete(service);
        case TaskStatus.failed:
        case TaskStatus.canceled:
        case TaskStatus.notFound:
          state = state.copyWith(
            error: 'No se pudo descargar la actualización.',
            clearDownloadProgress: true,
            clearInstallPending: true,
          );
        case TaskStatus.enqueued:
        case TaskStatus.running:
        case TaskStatus.paused:
        case TaskStatus.waitingToRetry:
          // Still in flight — progress events carry the bar.
          break;
      }
    }
  }

  /// Stable identity of the manifest a downloaded APK is bound to.
  static String manifestKey(AppManifest manifest) =>
      '${manifest.versionCode}:${manifest.sha256.toLowerCase()}';

  Future<void> _onDownloadComplete(ApkDownloadService service) async {
    var status = state.status;
    if (status is! UpdateAvailable) {
      // The in-flight manifest lives only in state.status, and a concurrent
      // check (resume-time auto-check hitting a network blip → UpdateUnknown)
      // may have overwritten it mid-download. NEVER drop the completion
      // silently — re-fetch the manifest so the finished file can be verified
      // against the CURRENT server truth.
      try {
        final result = await ref.read(appUpdateServiceProvider).checkForUpdate();
        state = state.copyWith(status: result);
      } catch (_) {
        // checkForUpdate never throws by contract; belt and suspenders.
      }
      status = state.status;
      if (status is! UpdateAvailable) {
        // Still no manifest to verify against → surface it (a visible retry
        // beats a frozen progress bar wedged just under 100%).
        state = state.copyWith(
          error:
              'La descarga terminó pero no se pudo confirmar la actualización. '
              'Vuelve a buscar actualizaciones.',
          clearDownloadProgress: true,
          clearInstallPending: true,
        );
        return;
      }
    }
    try {
      final path = await service.apkFilePath(status.manifest);
      // SHA-256 gate still runs BEFORE the APK is ever handed to the installer.
      await service.verifyApk(path, status.manifest.sha256);
      state = state.copyWith(
        downloadedApkPath: path,
        downloadedApkKey: manifestKey(status.manifest),
        downloadProgress: 1,
      );
      // Tell the user it's ready — a tap routes to /settings/updates to install.
      await ref.read(updateNotificationsProvider).showUpdateReady(status.versionName);
      // One-tap flow in progress? Continue straight into the install.
      if (state.installPending) await _tryInstall();
    } on ApkDownloadException catch (e) {
      state = state.copyWith(error: e.message, clearDownloadProgress: true);
    } catch (_) {
      state = state.copyWith(
        error: 'No se pudo verificar la actualización.',
        clearDownloadProgress: true,
      );
    }
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
    // DESKTOP TAKES A DIFFERENT ROUTE ENTIRELY. There is no APK and no package
    // installer; the release is root-owned. Asking systemd is the only path
    // that needs no privilege from the app and no terminal from the user.
    if (isDesktopPlatform(ref.read(hostOperatingSystemProvider))) {
      await _requestDesktopUpdate();
      return;
    }
    state = state.copyWith(installPending: true, clearError: true);
    // Already verified on disk FOR THIS manifest? Install straight away. A
    // path bound to an older manifest never reaches the installer.
    if (state.downloadedApkPath != null &&
        state.downloadedApkKey == manifestKey(status.manifest)) {
      await _tryInstall();
      return;
    }
    // Otherwise kick off (or attach to) the background download. Completion +
    // the follow-on install are driven by the app-level updates listener, which
    // sees [installPending] and continues into _tryInstall — so the flow no
    // longer depends on this method staying awaited on the Updates screen.
    await downloadUpdate();
  }

  /// Ask the system updater to run. The app never installs anything itself
  /// here — it creates one file and systemd, already root, takes over.
  Future<void> _requestDesktopUpdate() async {
    state = state.copyWith(clearError: true);
    try {
      await ref.read(desktopUpdateTriggerProvider).requestUpdate();
      state = state.copyWith(desktopUpdateRequested: true);
    } on DesktopUpdateUnavailableException catch (e) {
      // Fail loudly: a silent no-op here means the user waits forever for an
      // update nobody is going to perform.
      state = state.copyWith(error: e.message, desktopUpdateRequested: false);
    } catch (_) {
      state = state.copyWith(
        error: 'No se pudo pedir la actualización al sistema.',
        desktopUpdateRequested: false,
      );
    }
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

    // MANIFEST CHANGED while an older APK sat downloaded+verified? Drop the
    // stale binding (and reclaim the file) so the NEW APK is downloaded and
    // verified against the new sha — never install a file whose hash was only
    // ever checked against a previous manifest.
    if (state.downloadedApkPath != null &&
        state.downloadedApkKey != manifestKey(result.manifest)) {
      final stalePath = state.downloadedApkPath!;
      state = state.copyWith(clearDownloadedApkPath: true, clearDownloadProgress: true);
      try {
        await File(stalePath).delete();
      } catch (_) {
        // Best effort — the cleared binding is what prevents the stale install.
      }
    }

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

  /// Start (or attach to) the background download of the available APK.
  /// Progress, verification, and completion are handled asynchronously by the
  /// app-level updates listener ([_onDownloadUpdate]); this method only ignites
  /// the transfer and never awaits it, so it survives leaving the screen.
  Future<void> downloadUpdate() async {
    final status = state.status;
    if (status is! UpdateAvailable) return;
    // Already downloaded + verified — but only when the file is bound to THIS
    // manifest; a stale binding (older versionCode/sha) must not short-circuit
    // the fresh download.
    if (state.downloadedApkPath != null &&
        state.downloadedApkKey == manifestKey(status.manifest)) {
      return;
    }
    if (state.downloadedApkPath != null) {
      // Defensive: check() normally clears this on a manifest change; if a
      // stale binding survives, drop it here so the re-download can proceed.
      state = state.copyWith(clearDownloadedApkPath: true);
    }
    // Seed the bar to 0 only when starting fresh — a re-entry while a download
    // is already in flight must NOT reset visible progress back to zero.
    if (state.downloadProgress == null) {
      state = state.copyWith(downloadProgress: 0, clearError: true);
    }
    try {
      // Returns false when it attached to an already-running task (no restart).
      await ref.read(apkDownloadServiceProvider).startDownload(status.manifest);
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
