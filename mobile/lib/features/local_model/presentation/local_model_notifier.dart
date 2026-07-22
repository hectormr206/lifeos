import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/notification_permission.dart';
import 'local_model_providers.dart';

/// UI state for the model-manager screen (roadmap SLICE 1): download +
/// installed status for the on-device weights.
class LocalModelManagerState {
  const LocalModelManagerState({
    this.installed = false,
    this.checking = true,
    this.downloading = false,
    this.progress = 0.0,
    this.error,
    this.notificationPermission,
  });

  /// Weights are downloaded + installed on this device.
  final bool installed;

  /// The initial "is it installed?" probe is still running.
  final bool checking;

  /// A download is currently in flight.
  final bool downloading;

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

  LocalModelManagerState copyWith({
    bool? installed,
    bool? checking,
    bool? downloading,
    double? progress,
    String? error,
    NotificationPermission? notificationPermission,
  }) =>
      LocalModelManagerState(
        installed: installed ?? this.installed,
        checking: checking ?? this.checking,
        downloading: downloading ?? this.downloading,
        progress: progress ?? this.progress,
        error: error,
        // Preserve once known — a progress tick must not wipe the recorded
        // permission outcome.
        notificationPermission: notificationPermission ?? this.notificationPermission,
      );
}

/// Drives the model-manager screen: probes installation on build and runs the
/// download (delegating entirely to the [LocalLlmEngine]). Never performs the
/// download itself, so it is fully testable with a fake engine.
class LocalModelManagerNotifier extends Notifier<LocalModelManagerState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial installed-probe deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  LocalModelManagerState build() {
    _bootstrapFuture = _refreshInstalled();
    return const LocalModelManagerState();
  }

  Future<void> _refreshInstalled() async {
    try {
      final installed = await ref.read(localLlmEngineProvider).isModelInstalled();
      state = state.copyWith(installed: installed, checking: false);
    } catch (error) {
      state = state.copyWith(checking: false, error: 'No se pudo comprobar el modelo: $error');
    }
  }

  /// Downloads + installs the weights, streaming progress into [state].
  ///
  /// Before the fetch it requests the Android 13+ notification permission so
  /// `background_downloader` can post its status-bar progress notification.
  /// That permission is RECOMMENDED, never REQUIRED: empirically the download
  /// completes without it (only the visible notification is suppressed), so the
  /// request outcome is recorded for the UI but NEVER gates the download — even
  /// a denial falls straight through to the install attempt. Re-tapping
  /// download re-requests it (Android re-prompts after a soft denial).
  Future<void> download() async {
    if (state.downloading) return;
    state = state.copyWith(downloading: true, progress: 0, error: null);
    state = state.copyWith(notificationPermission: await _requestNotificationPermission());
    try {
      await for (final progress in ref.read(localLlmEngineProvider).downloadModel()) {
        state = state.copyWith(progress: progress);
      }
      state = state.copyWith(downloading: false, installed: true, progress: 1);
    } catch (error) {
      state = state.copyWith(downloading: false, error: 'La descarga falló: $error');
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
