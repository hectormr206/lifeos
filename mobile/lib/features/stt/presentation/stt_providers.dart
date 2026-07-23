import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/background_downloader_stt_model_gateway.dart';
import '../data/sherpa_stt_service.dart';
import '../domain/speech_to_text.dart';
import '../domain/stt_model.dart';
import '../domain/stt_model_gateway.dart';

/// Manages the on-device Whisper model: probing whether it is installed and
/// downloading it on first use. Overridden with a fake in tests.
final sttModelGatewayProvider = Provider<SttModelGateway>(
  (ref) => BackgroundDownloaderSttModelGateway(),
);

/// On-device speech-to-text service. Lazy-loads + disposes the recognizer per
/// call (see [SherpaSttService]). Overridden with a fake in tests.
final speechToTextProvider = Provider<SpeechToText>(
  (ref) => SherpaSttService(ref.watch(sttModelGatewayProvider)),
);

/// Drives the model-download affordance and progress (roadmap slice B2).
///
/// Hydrates its status from the gateway (Ready when the files are already on
/// disk, else Absent), and [download] streams 0..1 progress into the state so
/// the UI can show a progress bar. Never throws to callers — a failed download
/// lands in [SttModelFailed] so the user can retry.
final sttModelDownloadProvider =
    NotifierProvider<SttModelDownloadNotifier, SttModelStatus>(SttModelDownloadNotifier.new);

class SttModelDownloadNotifier extends Notifier<SttModelStatus> {
  Future<void>? _hydration;
  bool _downloading = false;

  /// Lets tests await the initial installed-probe deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  SttModelStatus build() {
    _hydration = _hydrate();
    return const SttModelAbsent();
  }

  Future<void> _hydrate() async {
    try {
      final installed = await ref.read(sttModelGatewayProvider).installedModel();
      state = installed != null ? const SttModelReady() : const SttModelAbsent();
    } catch (_) {
      state = const SttModelAbsent();
    }
  }

  /// Whether the model is already on disk (usable now).
  bool get isReady => state is SttModelReady;

  /// Downloads the model, streaming progress into [state]. No-op when a
  /// download is already in flight or the model is already ready.
  Future<void> download() async {
    if (_downloading || state is SttModelReady) return;
    _downloading = true;
    state = const SttModelDownloading(0);
    try {
      await ref.read(sttModelGatewayProvider).download(
            onProgress: (p) => state = SttModelDownloading(p),
          );
      state = const SttModelReady();
    } catch (e) {
      state = SttModelFailed(e.toString());
    } finally {
      _downloading = false;
    }
  }
}
