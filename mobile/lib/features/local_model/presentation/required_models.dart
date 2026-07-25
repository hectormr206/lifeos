/// Unified "required on-device models" layer (option B: all-models-ready gate).
///
/// LifeOS runs four on-device models — the chat brain (gemma), STT (Whisper),
/// TTS (Piper) and the embedding model (EmbeddingGemma). Historically each one
/// downloaded lazily from its own trigger, so the experience could be half
/// broken (chat works but recall/voice do not). This layer composes the four
/// existing per-feature download providers into:
///   * [requiredModelsSummaryProvider] — a live, per-model status view;
///   * [lifeOsModelsReadyProvider]      — true only when all four are installed;
///   * [requiredModelsDownloadProvider] — a "Descargar todo" orchestrator that
///     downloads the MISSING ones sequentially (brain first, biggest).
///
/// It NEVER reimplements a download — every action delegates to the feature's
/// own gateway/notifier, so an already-installed model (e.g. the brain adopted
/// as v1 on the Pixel) is never re-downloaded.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../embedding/embed_model_warmup.dart';
import '../../embedding/embedding_providers.dart';
import '../../stt/domain/stt_model.dart';
import '../../stt/presentation/stt_providers.dart';
import '../../tts/domain/tts_voice.dart';
import '../../tts/presentation/tts_providers.dart';
import '../../voice_settings/domain/voice_catalog.dart';
import '../../voice_settings/presentation/voice_catalog_providers.dart';
import 'local_model_notifier.dart';

/// The four models the offline experience needs. Ordered biggest-first so
/// "Descargar todo" fetches the ~2.6 GB brain before the small companions.
enum RequiredModelId { brain, stt, tts, embed }

/// The lifecycle phase of one required model, collapsed from each feature's own
/// (differently-shaped) status into a single UI-facing enum.
enum RequiredModelPhase { installed, downloading, available, error }

/// A single required model's live view (phase + download progress).
@immutable
class RequiredModelView {
  const RequiredModelView({
    required this.id,
    required this.phase,
    this.progress = 0,
    this.usesSystemVoice = false,
  });

  final RequiredModelId id;
  final RequiredModelPhase phase;

  /// TTS slot only: true when the requirement is satisfied by the DEVICE/system
  /// voice (the `system` sentinel after the last neural voice was deleted) —
  /// nothing to download, so the slot reads "voz del sistema", not "pending".
  final bool usesSystemVoice;

  /// Download progress in `0.0..1.0` (meaningful only while [phase] is
  /// [RequiredModelPhase.downloading]).
  final double progress;

  bool get isInstalled => phase == RequiredModelPhase.installed;
  bool get isDownloading => phase == RequiredModelPhase.downloading;
  bool get hasError => phase == RequiredModelPhase.error;
}

/// The composed view over all four required models, with the derived numbers
/// the manager + the chat "Preparando LifeOS" panel render.
@immutable
class RequiredModelsSummary {
  const RequiredModelsSummary(this.models);

  final List<RequiredModelView> models;

  int get total => models.length;
  int get readyCount => models.where((m) => m.isInstalled).length;
  bool get allReady => total > 0 && readyCount == total;
  bool get anyDownloading => models.any((m) => m.isDownloading);
  bool get anyError => models.any((m) => m.hasError);

  /// The models still not installed (what the "Descargar todo" flow will fetch).
  List<RequiredModelView> get pending =>
      models.where((m) => !m.isInstalled).toList(growable: false);

  /// Aggregate readiness in `0.0..1.0`: an installed model counts as 1, a
  /// downloading one as its progress, everything else as 0.
  double get overallProgress {
    if (models.isEmpty) return 0;
    final sum = models.fold<double>(0, (acc, m) {
      if (m.isInstalled) return acc + 1;
      if (m.isDownloading) return acc + m.progress.clamp(0.0, 1.0);
      return acc;
    });
    return sum / models.length;
  }

  int get overallPercent => (overallProgress * 100).round();
}

/// Fail-soft probe of whether the SELECTED Piper voice is already on disk. The
/// catalog controller starts every voice Absent and probes asynchronously, so
/// readiness at rest still needs this direct seam.
final ttsVoiceInstalledProbeProvider = FutureProvider<bool>((ref) async {
  final voiceId = ref.watch(selectedVoiceProvider);
  // The system-voice sentinel needs NO files on disk: after the last neural
  // voice is deleted, speech falls back to the device TTS, so the requirement
  // is satisfied — probing for a "system.onnx" would report false forever and
  // lock chat behind "Preparando LifeOS" with nothing left to download.
  if (voiceId == VoiceCatalog.systemVoiceId) return true;
  try {
    final voice = await ref.watch(ttsVoiceGatewayProvider).installedVoice(voiceId);
    return voice != null;
  } catch (_) {
    return false;
  }
});

/// Fail-soft probe of whether the embedding model is already on disk. The
/// warmup notifier stays `idle` until fired, so readiness at rest needs this.
final embedModelInstalledProbeProvider = FutureProvider<bool>((ref) async {
  try {
    final paths = await ref.watch(embedModelGatewayProvider).installedModel();
    return paths != null;
  } catch (_) {
    return false;
  }
});

/// Live, composed status of all four required models. Watches each feature's
/// own provider so per-model progress and the overall line stay reactive as
/// downloads run.
final requiredModelsSummaryProvider = Provider<RequiredModelsSummary>((ref) {
  final brain = ref.watch(localModelManagerProvider);
  final stt = ref.watch(sttModelDownloadProvider);
  final selectedVoice = ref.watch(selectedVoiceProvider);
  final ttsIsSystem = selectedVoice == VoiceCatalog.systemVoiceId;
  final tts = ref.watch(voiceCatalogControllerProvider)[selectedVoice] ?? const TtsVoiceAbsent();
  final ttsProbeInstalled = ref.watch(ttsVoiceInstalledProbeProvider).value ?? false;
  final embed = ref.watch(embedModelWarmupProvider);
  final embedProbeInstalled = ref.watch(embedModelInstalledProbeProvider).value ?? false;

  return RequiredModelsSummary([
    _brainView(brain),
    _sttView(stt),
    _ttsView(tts, ttsProbeInstalled, ttsIsSystem),
    _embedView(embed, embedProbeInstalled),
  ]);
});

/// True only when ALL four required models are installed — the single gate the
/// chat experience checks in local mode. Overridable in widget tests.
final lifeOsModelsReadyProvider =
    Provider<bool>((ref) => ref.watch(requiredModelsSummaryProvider).allReady);

RequiredModelView _brainView(LocalModelManagerState s) {
  if (s.installed) {
    return const RequiredModelView(id: RequiredModelId.brain, phase: RequiredModelPhase.installed);
  }
  if (s.downloading) {
    return RequiredModelView(
      id: RequiredModelId.brain,
      phase: RequiredModelPhase.downloading,
      progress: s.progress,
    );
  }
  if (s.error != null) {
    return const RequiredModelView(id: RequiredModelId.brain, phase: RequiredModelPhase.error);
  }
  return const RequiredModelView(id: RequiredModelId.brain, phase: RequiredModelPhase.available);
}

RequiredModelView _sttView(SttModelStatus s) => switch (s) {
      SttModelReady() =>
        const RequiredModelView(id: RequiredModelId.stt, phase: RequiredModelPhase.installed),
      SttModelDownloading(:final progress) => RequiredModelView(
          id: RequiredModelId.stt,
          phase: RequiredModelPhase.downloading,
          progress: progress,
        ),
      SttModelFailed() =>
        const RequiredModelView(id: RequiredModelId.stt, phase: RequiredModelPhase.error),
      SttModelAbsent() =>
        const RequiredModelView(id: RequiredModelId.stt, phase: RequiredModelPhase.available),
    };

RequiredModelView _ttsView(TtsVoiceStatus s, bool probeInstalled, bool isSystemVoice) {
  if (isSystemVoice) {
    // The system sentinel is a VALID satisfied speech configuration: the device
    // TTS needs no download, so the gate must never hold chat hostage for it.
    return const RequiredModelView(
      id: RequiredModelId.tts,
      phase: RequiredModelPhase.installed,
      usesSystemVoice: true,
    );
  }
  if (s is TtsVoiceReady || probeInstalled) {
    return const RequiredModelView(id: RequiredModelId.tts, phase: RequiredModelPhase.installed);
  }
  if (s is TtsVoiceDownloading) {
    return RequiredModelView(
      id: RequiredModelId.tts,
      phase: RequiredModelPhase.downloading,
      progress: s.progress,
    );
  }
  if (s is TtsVoiceFailed) {
    return const RequiredModelView(id: RequiredModelId.tts, phase: RequiredModelPhase.error);
  }
  return const RequiredModelView(id: RequiredModelId.tts, phase: RequiredModelPhase.available);
}

RequiredModelView _embedView(EmbedModelWarmupState s, bool probeInstalled) {
  if (s.isReady || probeInstalled) {
    return const RequiredModelView(id: RequiredModelId.embed, phase: RequiredModelPhase.installed);
  }
  switch (s.status) {
    case EmbedModelWarmupStatus.downloading:
      return RequiredModelView(
        id: RequiredModelId.embed,
        phase: RequiredModelPhase.downloading,
        progress: s.progress,
      );
    case EmbedModelWarmupStatus.failed:
      return const RequiredModelView(id: RequiredModelId.embed, phase: RequiredModelPhase.error);
    case EmbedModelWarmupStatus.idle:
    case EmbedModelWarmupStatus.ready:
      return const RequiredModelView(id: RequiredModelId.embed, phase: RequiredModelPhase.available);
  }
}

/// Orchestrates "Descargar todo": downloads the MISSING required models
/// sequentially (brain first), delegating each to its own feature notifier so
/// nothing is re-downloaded and every gateway's resumable background download
/// is reused. Its [bool] state is simply "a sequence is running".
final requiredModelsDownloadProvider =
    NotifierProvider<RequiredModelsDownloadNotifier, bool>(RequiredModelsDownloadNotifier.new);

class RequiredModelsDownloadNotifier extends Notifier<bool> {
  Future<void>? _run;

  /// Lets tests await the in-flight sequence deterministically.
  Future<void> get done => _run ?? Future<void>.value();

  @override
  bool build() => false;

  /// Downloads every missing model in order (brain → stt → tts → embed),
  /// awaiting each before starting the next. Single-flight: a second call while
  /// one is running is a no-op. Each step is guarded so an already-installed
  /// model is skipped — the brain in particular is NEVER re-downloaded.
  Future<void> downloadAll() {
    if (state) return _run ?? Future<void>.value();
    state = true;
    return _run = _sequence();
  }

  Future<void> _sequence() async {
    try {
      await _ensureBrain();
      await _ensureStt();
      await _ensureTts();
      await _ensureEmbed();
    } finally {
      state = false;
      _run = null;
    }
  }

  /// Retries a single model's download (per-model "reintentar").
  Future<void> retry(RequiredModelId id) async {
    switch (id) {
      case RequiredModelId.brain:
        await _ensureBrain();
      case RequiredModelId.stt:
        await _ensureStt();
      case RequiredModelId.tts:
        await _ensureTts();
      case RequiredModelId.embed:
        await _ensureEmbed();
    }
  }

  Future<void> _ensureBrain() async {
    final brain = ref.read(localModelManagerProvider);
    // The manager's download() has no installed-guard (it doubles as the OTA
    // update path), so we MUST skip it here when the weights are already on
    // disk — the whole "existing install must not re-download 2.6 GB" rule.
    if (brain.installed || brain.downloading) return;
    await ref.read(localModelManagerProvider.notifier).download();
  }

  Future<void> _ensureStt() async {
    if (ref.read(sttModelDownloadProvider) is SttModelReady) return;
    await ref.read(sttModelDownloadProvider.notifier).download();
  }

  Future<void> _ensureTts() async {
    final voiceId = ref.read(selectedVoiceProvider);
    // The system-voice sentinel is not a downloadable catalog voice — the
    // requirement is already satisfied by the device TTS, so this is an
    // explicit no-op (VoiceCatalogController.download would silently ignore
    // the unknown id anyway; being explicit keeps the invariant readable).
    if (voiceId == VoiceCatalog.systemVoiceId) return;
    if (ref.read(voiceCatalogControllerProvider)[voiceId] is TtsVoiceReady) return;
    // download() itself checks installedVoice and lands Ready without fetching
    // when the voice is already on disk, so this never re-downloads either.
    await ref.read(voiceCatalogControllerProvider.notifier).download(voiceId);
  }

  Future<void> _ensureEmbed() async {
    if (ref.read(embedModelWarmupProvider).isReady) return;
    // ensureStarted() probes first; an already-installed model lands ready
    // without a download (and runs its vector backfill).
    await ref.read(embedModelWarmupProvider.notifier).ensureStarted();
  }
}
