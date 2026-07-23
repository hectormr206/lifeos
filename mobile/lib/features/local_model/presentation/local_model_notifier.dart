import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/brain_model_manifest.dart';
import '../domain/brain_model_version_store.dart';
import '../domain/notification_permission.dart';
import 'local_model_providers.dart';

/// UI state for the model-manager screen (roadmap SLICE 1 + brain-model OTA):
/// download + installed status for the on-device weights, plus the tracked
/// installed version and the latest server manifest so the screen can surface
/// "hay un nuevo modelo disponible".
class LocalModelManagerState {
  const LocalModelManagerState({
    this.installed = false,
    this.checking = true,
    this.downloading = false,
    this.deleting = false,
    this.progress = 0.0,
    this.error,
    this.notificationPermission,
    this.manifest,
    this.installedVersionCode,
  });

  /// Weights are downloaded + installed on this device.
  final bool installed;

  /// The initial "is it installed?" probe is still running.
  final bool checking;

  /// A download (fresh install OR update) is currently in flight.
  final bool downloading;

  /// A deletion (freeing the on-disk weights) is currently in flight.
  final bool deleting;

  /// Download progress in `0.0..1.0` (meaningful only while [downloading]).
  final double progress;

  /// Last error message (download failure / probe failure), if any.
  final String? error;

  /// Outcome of the last notification-permission request (null until the user
  /// first taps download). Drives the "activá las notificaciones" rationale +
  /// the denied / permanently-denied recovery UI. Notifications are RECOMMENDED
  /// (to see the OS download-progress notification), never REQUIRED — a denial
  /// never blocks the download.
  final NotificationPermission? notificationPermission;

  /// Latest brain-model manifest fetched from the VPS (fail-soft null when
  /// offline / unconfigured / nothing published).
  final BrainModelManifest? manifest;

  /// versionCode of the tracked installed model (null when nothing installed
  /// or the version store is unavailable).
  final int? installedVersionCode;

  /// "Hay un nuevo modelo disponible": the server advertises a strictly newer
  /// versionCode than what is installed. Only meaningful when installed —
  /// a fresh device just sees the normal download button. NEVER auto-triggers
  /// a download (2.6GB): the user has to tap.
  bool get updateAvailable =>
      installed && manifest != null && manifest!.versionCode > (installedVersionCode ?? 0);

  LocalModelManagerState copyWith({
    bool? installed,
    bool? checking,
    bool? downloading,
    bool? deleting,
    double? progress,
    String? error,
    NotificationPermission? notificationPermission,
    BrainModelManifest? manifest,
    int? installedVersionCode,
    bool clearInstalledVersion = false,
  }) =>
      LocalModelManagerState(
        installed: installed ?? this.installed,
        checking: checking ?? this.checking,
        downloading: downloading ?? this.downloading,
        deleting: deleting ?? this.deleting,
        progress: progress ?? this.progress,
        error: error,
        // Preserve once known — a progress tick must not wipe the recorded
        // permission outcome / manifest / tracked version.
        notificationPermission: notificationPermission ?? this.notificationPermission,
        manifest: manifest ?? this.manifest,
        installedVersionCode: clearInstalledVersion
            ? null
            : (installedVersionCode ?? this.installedVersionCode),
      );
}

/// Drives the model-manager screen: probes installation on build, adopts
/// untracked installs in place (migration), checks the VPS manifest for a
/// newer model (fail-soft), and runs the download — via the OTA gateway when
/// configured (download → sha256 verify → hand the LOCAL file to the engine),
/// else via the legacy in-engine network install. Never performs any I/O
/// itself, so it is fully testable with fakes.
class LocalModelManagerNotifier extends Notifier<LocalModelManagerState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial installed-probe + update-check
  /// deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  LocalModelManagerState build() {
    _bootstrapFuture = _bootstrap();
    return const LocalModelManagerState();
  }

  Future<void> _bootstrap() async {
    await _refreshInstalled();
    await _adoptUntrackedInstall();
    await _checkForUpdate();
  }

  Future<void> _refreshInstalled() async {
    try {
      final installed = await ref.read(localLlmEngineProvider).isModelInstalled();
      state = state.copyWith(installed: installed, checking: false);
    } catch (error) {
      state = state.copyWith(checking: false, error: 'No se pudo comprobar el modelo: $error');
    }
  }

  /// MIGRATION (adopt in place): an already-installed model with no tracked
  /// version — e.g. the original HuggingFace download that predates the OTA
  /// flow — is recorded as versionCode 1 WITHOUT re-downloading 2.6GB. From
  /// then on the normal manifest comparison applies.
  Future<void> _adoptUntrackedInstall() async {
    if (!state.installed) return;
    try {
      final store = ref.read(brainModelVersionStoreProvider);
      var tracked = await store.installed();
      if (tracked == null) {
        tracked = const InstalledBrainModel(
          modelName: kBrainModelName,
          versionCode: kBrainModelAdoptedVersionCode,
        );
        await store.setInstalled(tracked);
      }
      state = state.copyWith(installedVersionCode: tracked.versionCode);
    } catch (_) {
      // Version store unavailable (e.g. no platform channel in tests) — the
      // update comparison just stays inert; never blocks the screen.
    }
  }

  /// Fail-soft manifest check ("hay un nuevo modelo disponible" surfaces via
  /// [LocalModelManagerState.updateAvailable]). Offline / unconfigured /
  /// nothing published → null → no banner, no error.
  Future<void> _checkForUpdate() async {
    try {
      final manifest = await ref.read(brainModelUpdateGatewayProvider).fetchManifest();
      if (manifest != null) state = state.copyWith(manifest: manifest);
    } catch (_) {
      // The gateway is already fail-soft; this is belt-and-braces so the
      // bootstrap can never crash on an update check.
    }
  }

  /// Downloads + installs the weights (fresh install AND update — same flow),
  /// streaming progress into [state].
  ///
  /// OTA path (source configured): fetch the manifest if needed → download the
  /// file ourselves via the gateway (resumable background_downloader) →
  /// sha256-verify → hand the verified LOCAL path to the engine
  /// (`installModelFromFile`) → track modelName+versionCode. On an update the
  /// verified file replaces the old one (stable path), so the old weights are
  /// gone the moment the swap lands.
  ///
  /// Legacy path (source NOT configured, e.g. dev builds): the engine's own
  /// network install, tracked as versionCode 1.
  ///
  /// Before the fetch it requests the Android 13+ notification permission so
  /// `background_downloader` can post its status-bar progress notification.
  /// That permission is RECOMMENDED, never REQUIRED: the request outcome is
  /// recorded for the UI but NEVER gates the download.
  Future<void> download() async {
    if (state.downloading || state.deleting) return;
    state = state.copyWith(downloading: true, progress: 0, error: null);
    state = state.copyWith(notificationPermission: await _requestNotificationPermission());
    try {
      final gateway = ref.read(brainModelUpdateGatewayProvider);
      if (gateway.isConfigured) {
        final manifest = state.manifest ?? await gateway.fetchManifest();
        if (manifest == null) {
          throw StateError('no se pudo obtener el manifiesto del modelo');
        }
        final path = await gateway.downloadAndVerify(
          manifest,
          onProgress: (progress) => state = state.copyWith(progress: progress),
        );
        await ref.read(localLlmEngineProvider).installModelFromFile(path);
        final trackedName = manifest.modelName.isEmpty ? kBrainModelName : manifest.modelName;
        await _trackInstalled(trackedName, manifest.versionCode);
        state = state.copyWith(
          downloading: false,
          installed: true,
          progress: 1,
          manifest: manifest,
          installedVersionCode: manifest.versionCode,
        );
      } else {
        await for (final progress in ref.read(localLlmEngineProvider).downloadModel()) {
          state = state.copyWith(progress: progress);
        }
        await _trackInstalled(kBrainModelName, kBrainModelAdoptedVersionCode);
        state = state.copyWith(
          downloading: false,
          installed: true,
          progress: 1,
          installedVersionCode: kBrainModelAdoptedVersionCode,
        );
      }
    } catch (error) {
      state = state.copyWith(downloading: false, error: 'La descarga falló: $error');
    }
  }

  /// Best-effort version tracking; a store failure never fails the install
  /// (the next bootstrap's adopt-in-place will repair the record).
  Future<void> _trackInstalled(String modelName, int versionCode) async {
    try {
      await ref.read(brainModelVersionStoreProvider).setInstalled(
            InstalledBrainModel(modelName: modelName, versionCode: versionCode),
          );
    } catch (_) {/* best effort */}
  }

  /// Deletes the installed weights (freeing ~2.6GB) so the model can be
  /// re-downloaded later. Besides the engine uninstall this ALSO deletes the
  /// OTA-downloaded file (flutter_gemma never deletes external
  /// `fromFile`-installed files) and clears the tracked version. On success
  /// [LocalModelManagerState.installed] flips to `false`; the on-device toggle
  /// is then forced OFF (and persisted) because local mode is impossible
  /// without weights. Delete failures surface an error and leave the weights
  /// in place; the screen never crashes.
  Future<void> deleteModel() async {
    if (state.deleting || state.downloading) return;
    state = state.copyWith(deleting: true, error: null);
    try {
      await ref.read(localLlmEngineProvider).deleteModel();
      // The uninstall only removes flutter_gemma's registration/dir — the OTA
      // file at our stable path is ours to free. Fail-soft: the uninstall
      // already succeeded, a leftover file must not surface as a failure.
      try {
        await ref.read(brainModelUpdateGatewayProvider).deleteLocalFile();
      } catch (_) {/* best effort */}
      try {
        await ref.read(brainModelVersionStoreProvider).clear();
      } catch (_) {/* best effort */}
      state = state.copyWith(deleting: false, installed: false, clearInstalledVersion: true);
      // Force local mode off now that the weights are gone (idempotent if it
      // was already off). Uses the enabled-notifier so the choice is persisted.
      await ref.read(localModelEnabledProvider.notifier).setEnabled(false);
    } catch (error) {
      state = state.copyWith(deleting: false, error: 'No se pudo eliminar el modelo: $error');
    }
  }

  /// Best-effort notification-permission request; a failure degrades to
  /// [NotificationPermission.unsupported] so it can never block the download.
  Future<NotificationPermission> _requestNotificationPermission() async {
    try {
      return await ref.read(notificationPermissionGatewayProvider).request();
    } catch (_) {
      return NotificationPermission.unsupported;
    }
  }

  /// Opens the app's system settings so the user can enable notifications after
  /// a permanent denial (the OS won't prompt again). Best-effort — a failure is
  /// swallowed rather than crashing the screen.
  Future<void> openNotificationSettings() async {
    try {
      await ref.read(notificationPermissionGatewayProvider).openSettings();
    } catch (_) {
      // Nothing more we can do from here; the user can open Settings manually.
    }
  }
}

final localModelManagerProvider =
    NotifierProvider<LocalModelManagerNotifier, LocalModelManagerState>(LocalModelManagerNotifier.new);
