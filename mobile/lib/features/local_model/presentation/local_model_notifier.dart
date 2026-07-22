import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  LocalModelManagerState copyWith({
    bool? installed,
    bool? checking,
    bool? downloading,
    double? progress,
    String? error,
  }) =>
      LocalModelManagerState(
        installed: installed ?? this.installed,
        checking: checking ?? this.checking,
        downloading: downloading ?? this.downloading,
        progress: progress ?? this.progress,
        error: error,
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
  Future<void> download() async {
    if (state.downloading) return;
    state = state.copyWith(downloading: true, progress: 0, error: null);
    try {
      await for (final progress in ref.read(localLlmEngineProvider).downloadModel()) {
        state = state.copyWith(progress: progress);
      }
      state = state.copyWith(downloading: false, installed: true, progress: 1);
    } catch (error) {
      state = state.copyWith(downloading: false, error: 'La descarga falló: $error');
    }
  }
}

final localModelManagerProvider =
    NotifierProvider<LocalModelManagerNotifier, LocalModelManagerState>(LocalModelManagerNotifier.new);
