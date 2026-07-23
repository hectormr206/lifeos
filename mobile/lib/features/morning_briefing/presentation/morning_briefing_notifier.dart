import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../local_model/domain/local_llm_engine.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../data/source_content_extractor.dart';
import '../domain/morning_briefing.dart';
import '../domain/source_fetcher.dart';
import 'morning_briefing_providers.dart';

/// Where the on-device briefing pipeline currently is, so the UI can show a
/// meaningful progress/loading state (reusing the model-loading pattern).
enum BriefingPhase {
  /// Not running — showing the last briefing (or the empty state).
  idle,

  /// Bringing the on-device weights resident in RAM (loads on demand).
  loadingModel,

  /// Fetching + extracting the configured sources.
  fetching,

  /// The model is summarizing.
  summarizing,

  /// A briefing was produced this run.
  done,

  /// The run failed; [MorningBriefingState.error] carries a neutral-Spanish
  /// message.
  error,
}

/// Immutable UI state for the on-device "boletín matutino".
class MorningBriefingState {
  const MorningBriefingState({
    this.sources = const [],
    this.briefing,
    this.phase = BriefingPhase.idle,
    this.progressLabel,
    this.error,
  });

  /// Configured news-source URLs (the user adds/removes these).
  final List<String> sources;

  /// The last briefing produced (persisted so it survives navigation).
  final OnDeviceBriefing? briefing;

  final BriefingPhase phase;

  /// Human-readable progress line while [isGenerating] (e.g. "Resumiendo…").
  final String? progressLabel;

  /// Neutral-Spanish failure message (only set when [phase] is
  /// [BriefingPhase.error]).
  final String? error;

  bool get isGenerating =>
      phase == BriefingPhase.loadingModel ||
      phase == BriefingPhase.fetching ||
      phase == BriefingPhase.summarizing;

  MorningBriefingState copyWith({
    List<String>? sources,
    OnDeviceBriefing? briefing,
    BriefingPhase? phase,
    String? progressLabel,
    String? error,
  }) =>
      MorningBriefingState(
        sources: sources ?? this.sources,
        briefing: briefing ?? this.briefing,
        phase: phase ?? this.phase,
        progressLabel: progressLabel,
        error: error,
      );
}

/// Runs the ON-DEVICE morning-briefing pipeline and owns its UI state.
///
/// Pipeline (all on device, nothing leaves the phone):
///   1. load the local model on demand (idempotent; left loaded after),
///   2. for each configured source: HTTP GET → extract readable text
///      (feed items or stripped HTML), per-source try/catch so a failing
///      source is skipped, not fatal,
///   3. summarize each source with the model using the LONGSUM tuned sampling,
///   4. write a short overall intro, persist the briefing, and post a local
///      notification.
class MorningBriefingNotifier extends Notifier<MorningBriefingState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial hydration deterministically (mirrors the
  /// `ready` seam on the other notifiers).
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  /// LONGSUM tuned sampling for gemma-4-E2B, straight from the `model_audit`
  /// tune-to-peak LONGSUM recipe (the summarization role). This is DELIBERATELY
  /// different from the general/vision tuned recipe (0.6/20/0.95): summaries
  /// want the lower-temperature longsum values for factual, non-divergent
  /// output. Passed as per-call overrides to [LocalLlmEngine.generate].
  static const double longsumTemperature = 0.2;
  static const int longsumTopK = 20;
  static const double longsumTopP = 0.9;

  @override
  MorningBriefingState build() {
    _bootstrapFuture = _hydrate();
    return const MorningBriefingState();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = ref.read(morningBriefingPreferencesProvider);
      final sources = await prefs.sources();
      final last = await prefs.lastBriefing();
      state = state.copyWith(sources: sources, briefing: last);
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // keep the safe empty default rather than crashing.
    }
  }

  /// Adds [url] to the configured sources (trimmed, de-duplicated) and persists.
  Future<void> addSource(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || state.sources.contains(trimmed)) return;
    final next = [...state.sources, trimmed];
    state = state.copyWith(sources: next);
    await _persistSources(next);
  }

  /// Removes [url] from the configured sources and persists.
  Future<void> removeSource(String url) async {
    if (!state.sources.contains(url)) return;
    final next = state.sources.where((s) => s != url).toList();
    state = state.copyWith(sources: next);
    await _persistSources(next);
  }

  Future<void> _persistSources(List<String> urls) async {
    try {
      await ref.read(morningBriefingPreferencesProvider).setSources(urls);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
  }

  /// Runs the whole pipeline. No-op while already generating.
  Future<void> generate() async {
    if (state.isGenerating) return;
    final sources = state.sources;
    if (sources.isEmpty) {
      state = state.copyWith(
        phase: BriefingPhase.error,
        error: 'Agrega al menos una fuente de noticias para generar el boletín.',
      );
      return;
    }

    // 1) Load the model on demand (idempotent — stays loaded afterwards).
    state = state.copyWith(phase: BriefingPhase.loadingModel, progressLabel: 'Cargando el modelo…');
    try {
      await ref.read(localLlmEngineProvider).load();
    } catch (error) {
      state = state.copyWith(
        phase: BriefingPhase.error,
        error: 'No se pudo cargar el modelo: $error. '
            'Descarga el modelo en Ajustes › Modelo local e inténtalo de nuevo.',
      );
      return;
    }

    // 2 + 3) Fetch, extract, summarize each source.
    final engine = ref.read(localLlmEngineProvider);
    final fetcher = ref.read(sourceFetcherProvider);
    final extractor = ref.read(sourceContentExtractorProvider);
    final items = <BriefingItem>[];

    for (var i = 0; i < sources.length; i++) {
      final url = sources[i];
      state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Leyendo fuente ${i + 1} de ${sources.length}…',
      );
      final item = await _summarizeSource(url, engine: engine, fetcher: fetcher, extractor: extractor);
      if (item != null) items.add(item);
    }

    if (items.isEmpty) {
      state = state.copyWith(
        phase: BriefingPhase.error,
        error: 'No se pudo generar el boletín: ninguna fuente respondió con contenido legible.',
      );
      return;
    }

    // 4) Short overall intro over the collected summaries.
    state = state.copyWith(phase: BriefingPhase.summarizing, progressLabel: 'Redactando la introducción…');
    final intro = await _writeIntro(items, engine: engine);

    final briefing = OnDeviceBriefing(intro: intro, items: items, generatedAt: DateTime.now());
    state = state.copyWith(briefing: briefing, phase: BriefingPhase.done, progressLabel: null);

    // Persist + notify (best-effort; neither is allowed to break the run).
    try {
      await ref.read(morningBriefingPreferencesProvider).saveLastBriefing(briefing);
    } catch (_) {
      // In-memory briefing still shown even if persistence failed.
    }
    try {
      await ref.read(briefingNotificationsProvider).showBriefingReady();
    } catch (_) {
      // Notification is best-effort; the briefing is already on screen.
    }
  }

  /// Fetch + extract + summarize ONE source. Returns null (source skipped) on
  /// any per-source failure — a failing source is never fatal to the briefing.
  Future<BriefingItem?> _summarizeSource(
    String url, {
    required LocalLlmEngine engine,
    required SourceFetcher fetcher,
    required SourceContentExtractor extractor,
  }) async {
    try {
      final body = await fetcher.fetch(url);
      final extract = extractor.extract(body, url: url);
      if (extract.isEmpty) return null;

      state = state.copyWith(
        phase: BriefingPhase.summarizing,
        progressLabel: 'Resumiendo: ${extract.title}…',
      );
      final prompt = 'Resume en 2 o 3 frases, en español neutro y claro, la siguiente fuente de '
          'noticias. Devuelve solo el resumen, sin encabezados ni viñetas.\n\n'
          'Fuente: ${extract.title}\n\nContenido:\n${extract.text}';
      final result = await engine.generate(
        prompt,
        temperature: longsumTemperature,
        topK: longsumTopK,
        topP: longsumTopP,
      );
      final summary = result.text.trim();
      if (summary.isEmpty) return null;
      return BriefingItem(sourceTitle: extract.title, url: url, summary: summary);
    } catch (_) {
      // Skip this one source; the rest of the briefing still proceeds.
      return null;
    }
  }

  Future<String> _writeIntro(List<BriefingItem> items, {required LocalLlmEngine engine}) async {
    try {
      final titles = items.map((i) => '- ${i.sourceTitle}').join('\n');
      final prompt = 'Escribe una introducción muy breve (1 o 2 frases), en español neutro, para un '
          'boletín matutino que reúne estas fuentes. Devuelve solo la introducción.\n\n$titles';
      final result = await engine.generate(
        prompt,
        temperature: longsumTemperature,
        topK: longsumTopK,
        topP: longsumTopP,
      );
      final intro = result.text.trim();
      if (intro.isNotEmpty) return intro;
    } catch (_) {
      // Fall through to a static intro below.
    }
    return 'Esto es lo más destacado de tus fuentes esta mañana.';
  }
}

final morningBriefingNotifierProvider =
    NotifierProvider<MorningBriefingNotifier, MorningBriefingState>(MorningBriefingNotifier.new);
