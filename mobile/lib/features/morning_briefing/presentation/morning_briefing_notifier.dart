import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../../settings/domain/settings_bridge.dart';
import '../../settings/data/synced_settings_store.dart';
import '../domain/briefing_source.dart';
import '../../../core/timezone/timezone_providers.dart';
import '../../../l10n/locale_providers.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../../local_model/domain/on_device_translator.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../data/source_content_extractor.dart';
import '../domain/briefing_harvester.dart';
import '../domain/briefing_schedule.dart';
import '../domain/briefing_brief_writer.dart';
import '../domain/briefing_scheduler.dart';
import '../domain/briefing_translation.dart';
import '../domain/morning_briefing.dart';
import '../domain/summary_failure.dart';
import 'morning_briefing_providers.dart';

export '../domain/briefing_harvester.dart' show hnFrontPageUrl, hnItemUrlPrefix;

/// Where the on-device briefing pipeline currently is, so the UI can show a
/// meaningful progress/loading state.
enum BriefingPhase {
  /// Not running — showing the last briefing (or the empty state).
  idle,

  /// Fetching + parsing the configured sources (fast: NO model summarization).
  fetching,

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
    this.schedule = const BriefingSchedule(),
    this.phase = BriefingPhase.idle,
    this.progressLabel,
    this.error,
    this.summarizingArticles = const {},
    this.summarizingComments = const {},
    this.queuedArticles = const {},
    this.queuedComments = const {},
    this.articleFailures = const {},
    this.commentFailures = const {},
    this.translationFailure,
    this.modelOnFallbackBackend = false,
  });

  /// Configured news-source URLs (the user adds/removes these).
  final List<BriefingSource> sources;

  /// The "Boletín automático" setting (daily trigger + hour).
  final BriefingSchedule schedule;

  /// The last briefing produced (persisted so it survives navigation).
  final OnDeviceBriefing? briefing;

  final BriefingPhase phase;

  /// Human-readable progress line while generating.
  final String? progressLabel;

  /// Neutral-Spanish failure message (only when [phase] is [BriefingPhase.error]).
  final String? error;

  /// Article keys whose on-demand full summary is being generated right now.
  final Set<String> summarizingArticles;

  /// Article keys whose on-demand HN comments summary is being generated.
  final Set<String> summarizingComments;

  /// Article keys whose full summary was REQUESTED and is waiting its turn on
  /// the shared model queue — accepted work that has not started yet. Kept
  /// apart from [summarizingArticles] so the card can say "en cola" instead of
  /// pretending the model is already writing.
  final Set<String> queuedArticles;

  /// Article keys whose comments summary is waiting its turn (see
  /// [queuedArticles]).
  final Set<String> queuedComments;

  /// Per-article on-demand full-summary failures (keyed by article key): the
  /// identified CAUSE plus the attempt count, never a pre-rendered sentence —
  /// the wording (and whether a retry is even offered) belongs to the UI.
  final Map<String, SummaryAttemptFailure> articleFailures;

  /// Per-article on-demand comments-summary failures (see [articleFailures]).
  final Map<String, SummaryAttemptFailure> commentFailures;

  /// The engine failure behind items that stayed in their original language,
  /// when there was one. Translation drives the SAME engine as the summaries,
  /// so an unusable model breaks both — but only the summaries used to say so,
  /// and untranslated headlines just looked like a translator that had quietly
  /// skipped them. Null when the model ran (however imperfectly).
  final EngineFailureDetail? translationFailure;

  /// Whether the loaded model ended up on a slower fallback backend. Surfaced
  /// so a summary that suddenly takes minutes is legible as "slow" rather than
  /// "hung". See [LocalLlmEngine.usesFallbackBackend].
  final bool modelOnFallbackBackend;

  bool get isGenerating => phase == BriefingPhase.fetching;

  bool isSummarizingArticle(String key) => summarizingArticles.contains(key);
  bool isSummarizingComments(String key) => summarizingComments.contains(key);

  /// Whether the article's full summary was accepted and is waiting its turn.
  bool isQueuedArticle(String key) => queuedArticles.contains(key);

  /// Whether the article's comments summary was accepted and is waiting.
  bool isQueuedComments(String key) => queuedComments.contains(key);

  /// Running OR waiting — the guard against enqueuing the same article twice.
  bool isArticlePending(String key) =>
      isSummarizingArticle(key) || isQueuedArticle(key);

  /// Running OR waiting, for the comments summary.
  bool isCommentsPending(String key) =>
      isSummarizingComments(key) || isQueuedComments(key);

  MorningBriefingState copyWith({
    List<BriefingSource>? sources,
    OnDeviceBriefing? briefing,
    BriefingSchedule? schedule,
    BriefingPhase? phase,
    String? progressLabel,
    String? error,
    Set<String>? summarizingArticles,
    Set<String>? summarizingComments,
    Set<String>? queuedArticles,
    Set<String>? queuedComments,
    Map<String, SummaryAttemptFailure>? articleFailures,
    Map<String, SummaryAttemptFailure>? commentFailures,
    EngineFailureDetail? translationFailure,
    // The translation failure PERSISTS across the many unrelated copyWith calls
    // a summary makes (queued → running → done), unlike `error`/`progressLabel`
    // which are per-transition. Clearing it is therefore an explicit act — a
    // new generation that translated fine.
    bool clearTranslationFailure = false,
    bool? modelOnFallbackBackend,
  }) => MorningBriefingState(
    sources: sources ?? this.sources,
    briefing: briefing ?? this.briefing,
    schedule: schedule ?? this.schedule,
    phase: phase ?? this.phase,
    progressLabel: progressLabel,
    error: error,
    summarizingArticles: summarizingArticles ?? this.summarizingArticles,
    summarizingComments: summarizingComments ?? this.summarizingComments,
    queuedArticles: queuedArticles ?? this.queuedArticles,
    queuedComments: queuedComments ?? this.queuedComments,
    articleFailures: articleFailures ?? this.articleFailures,
    commentFailures: commentFailures ?? this.commentFailures,
    translationFailure: clearTranslationFailure
        ? null
        : (translationFailure ?? this.translationFailure),
    modelOnFallbackBackend:
        modelOnFallbackBackend ?? this.modelOnFallbackBackend,
  );
}

/// Runs the ON-DEVICE morning-briefing pipeline and owns its UI state.
///
/// REDESIGN: briefing generation does NO bulk model summarization (the old
/// pipeline summarized every source with the on-device model, which was slow +
/// fragile and left most sources incomplete). Generation is now just
/// fetch + parse (RSS/Atom/RDF + Hacker News) → freshness-filter (today/
/// yesterday) → group by source (cap 10) → persist. The on-device model runs
/// only ON DEMAND, per item, when the reader taps "Ver resumen completo" or
/// (HN only) "Ver resumen de comentarios".
class MorningBriefingNotifier extends Notifier<MorningBriefingState> {
  Future<void>? _bootstrapFuture;

  /// In-process daily trigger: while the app process is alive at the scheduled
  /// hour, this timer runs [generate] directly (fully autonomous, no tap).
  Timer? _autoRunTimer;

  /// Set once disposed, so an in-flight async arm (now awaiting the effective
  /// zone) never touches `state` afterwards.
  bool _disposed = false;

  /// How many times each article's full summary has been REQUESTED since its
  /// last success. A retry that fails instantly repaints the identical error,
  /// so the count is what tells the reader his tap was taken.
  final Map<String, int> _articleAttempts = {};

  /// The same, for the comments summary.
  final Map<String, int> _commentAttempts = {};

  /// Bumped by [stopTranslating] (and by every new [translateOpenBriefing]):
  /// an on-open translation only keeps going while the run it started with is
  /// still the current one. That is the whole cancellation mechanism — the
  /// native session has no "stop", so what we control is whether the NEXT batch
  /// is ever asked for, and whether a batch that came back late is published.
  int _translationRun = 0;

  /// Guard against two on-open translations of the same briefing overlapping
  /// (the screen is rebuilt on every state change).
  bool _translating = false;

  /// The grace before the on-open translation starts, as a CANCELLABLE timer
  /// rather than a bare `Future.delayed`: the reader who opens the briefing and
  /// leaves within the second must not leave a timer running behind him — and a
  /// pending timer that outlives the screen is exactly what a widget test
  /// refuses to end on.
  Timer? _graceTimer;
  Completer<void>? _graceDone;

  void _cancelGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
    final done = _graceDone;
    _graceDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Injectable clock for the schedule/auto-run logic (production uses the real
  /// clock). Freshness uses [clockProvider] instead (the device-timezone seam).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  /// LONGSUM tuned sampling for gemma-4-E2B (the summarization role): lower
  /// temperature for factual, non-divergent summaries. Passed as per-call
  /// overrides to [LocalLlmEngine.generate] for the on-demand summaries.
  /// How long the screen is left alone before the on-open translation starts.
  ///
  /// The reader has just arrived: the first frame, the fold he taps, and the
  /// summary he may ask for all come first. And the model may have been
  /// released for being idle ([IdleUnloadLlmEngine]), so the first batch can
  /// mean re-mapping ~2.6 GB of weights — a second of quiet is the difference
  /// between a screen that opens and a screen that opens while the phone is
  /// busy. It is a grace, not a throttle: after it, batches run back to back.
  static const Duration openTranslationGrace = Duration(milliseconds: 1200);

  static const double longsumTemperature = 0.2;
  static const int longsumTopK = 20;
  static const double longsumTopP = 0.9;

  @override
  MorningBriefingState build() {
    ref.onDispose(() {
      _disposed = true;
      _autoRunTimer?.cancel();
      _cancelGrace();
    });
    _bootstrapFuture = _hydrate();
    return const MorningBriefingState();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = ref.read(morningBriefingPreferencesProvider);
      final sources = await prefs.sources();
      final last = await prefs.lastBriefing();
      final schedule = await prefs.schedule();
      state = state.copyWith(
        sources: sources,
        briefing: last,
        schedule: schedule,
      );
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // keep the safe empty default rather than crashing.
    }
    await _armTriggers();
  }

  /// Adds a source under [section] (trimmed, de-duplicated by URL).
  ///
  /// De-duplication is by URL alone: the same feed filed under two sections
  /// would be fetched twice and read twice, which is a worse morning than a
  /// misfiled one.
  Future<void> addSource(
    String url, {
    String section = kDefaultBriefingSection,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    if (state.sources.any((s) => s.url == trimmed)) return;
    final next = [
      ...state.sources,
      BriefingSource(url: trimmed, section: section.trim()),
    ];
    state = state.copyWith(sources: next);
    await _persistSources(next);
  }

  /// Turn a source on or off without losing it.
  ///
  /// The built-in ones can only ever reach this, never [removeSource]: a
  /// curated default someone mutes in a bad week should be one tap from coming
  /// back, and a deleted one means going to find the URL again.
  Future<void> setSourceEnabled(String url, bool enabled) async {
    final next = [
      for (final source in state.sources)
        if (source.url == url) source.copyWith(enabled: enabled) else source,
    ];
    state = state.copyWith(sources: next);
    await _persistSources(next);
  }

  /// Removes [url] from the configured sources and persists.
  Future<void> removeSource(String url) async {
    // A shipped source is never deleted, only disabled — enforced here as well
    // as in the UI, because a list that can lose its defaults cannot get them
    // back.
    final target = state.sources.where((s) => s.url == url);
    if (target.isEmpty || !target.first.canDelete) return;
    final next = state.sources.where((s) => s.url != url).toList();
    state = state.copyWith(sources: next);
    await _persistSources(next);
  }

  Future<void> _persistSources(List<BriefingSource> sources) async {
    try {
      await ref.read(morningBriefingPreferencesProvider).setSources(sources);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
  }

  // ---------------------------------------------------------------------------
  // "Boletín automático" (scheduled autonomous run)
  // ---------------------------------------------------------------------------

  Future<void> setScheduleEnabled(bool enabled) =>
      _updateSchedule(state.schedule.copyWith(enabled: enabled));

  Future<void> setScheduleTime(int hour, int minute) =>
      _updateSchedule(state.schedule.copyWith(hour: hour, minute: minute));

  Future<void> _updateSchedule(BriefingSchedule schedule) async {
    state = state.copyWith(schedule: schedule);
    try {
      await ref.read(morningBriefingPreferencesProvider).saveSchedule(schedule);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
    // Y al grafo, que es lo que VIAJA: "quiero el boletín a las 7" es cierto
    // en todos los aparatos del usuario, y repetirlo en cada uno es la clase
    // de trabajo que hace que la gente deje de configurar nada.
    //
    // Sin bloquear y sólo si el grafo YA está abierto: esperar a que abra
    // dejaría el ajuste local sin guardar cuando el almacén tarda, y en un
    // test sin store colgaría el guardado entero. El próximo cambio, o el
    // próximo arranque, lo vuelve a intentar.
    final store = ref.read(localGraphStoreProvider).value;
    if (store != null) {
      unawaited(SyncedSettingsStore(store).put(
        'briefing.time',
        encodeScheduleSetting(
          enabled: schedule.enabled,
          hour: schedule.hour,
          minute: schedule.minute,
        ),
      ));
    }
    await _armTriggers();
  }

  /// (Re)arms ALL THREE triggers (WorkManager background generation + OS
  /// reminder + in-app timer) for the current schedule. Disabled → all
  /// cancelled. One-shot: every start/resume/run re-arms for the NEXT
  /// occurrence.
  /// The manual-override [tz.Location] for schedule math, or `null` in AUTOMATIC
  /// mode (device-local, unchanged). Best-effort — failures degrade to local.
  Future<tz.Location?> _overrideLocation() async {
    try {
      return (await ref.read(
        effectiveTimezoneProvider.future,
      )).overrideLocation;
    } catch (_) {
      return null;
    }
  }

  DateTime _nowIn(DateTime base, tz.Location? location) =>
      location == null ? base : tz.TZDateTime.from(base, location);

  Future<void> _armTriggers() async {
    _autoRunTimer?.cancel();
    _autoRunTimer = null;
    final scheduler = ref.read(briefingSchedulerProvider);
    final backgroundWork = ref.read(briefingBackgroundWorkProvider);
    final schedule = state.schedule;
    if (!schedule.enabled) {
      await scheduler.cancelReminder();
      await backgroundWork.cancel();
      return;
    }
    final location = await _overrideLocation();
    if (_disposed) return;
    final base = clock();
    final now = _nowIn(base, location);
    final next = schedule.nextRun(
      now,
      lastGeneratedAt: state.briefing?.generatedAt,
      location: location,
    );
    // REAL background generation ("Segundo plano", user opt-in): a WorkManager
    // one-off fires at the slot and generates with the app closed. The
    // reminder below stays as the graceful floor (OS deferred/killed the
    // task), and the in-app timer covers the app-open case — the shared
    // already-generated-today guard keeps the three from double-generating.
    // The work starts a lead earlier than the promised hour; the reminder and
    // the in-app timer keep their own meanings (the floor, and the app-open
    // case). All three still share the already-generated-today guard.
    final start = next.subtract(BriefingSchedule.lead);
    await backgroundWork.scheduleOneOff(start.difference(base));
    if (_disposed) return;
    await scheduler.scheduleReminder(next.add(kBriefingReminderGrace));
    if (_disposed) return;
    _autoRunTimer = Timer(start.difference(base), _onAutoRunTimer);
  }

  Future<void> _onAutoRunTimer() async {
    await maybeAutoGenerate();
  }

  /// Entry point for every trigger path: runs [generate] IF the schedule says a
  /// run is due AND today's briefing does not exist yet. Always re-arms after.
  Future<void> maybeAutoGenerate() async {
    await ready;
    if (_disposed || state.isGenerating) return;
    final location = await _overrideLocation();
    if (_disposed) return;
    final due = state.schedule.shouldRunNow(
      _nowIn(clock(), location),
      lastGeneratedAt: state.briefing?.generatedAt,
      location: location,
    );
    if (due) {
      await ref.read(briefingSchedulerProvider).cancelReminder();
      await generate();
    }
    await _armTriggers();
  }

  // ---------------------------------------------------------------------------
  // Generation: fetch + parse + freshness + group (NO model summarization)
  // ---------------------------------------------------------------------------

  /// Runs the whole (fast) pipeline. No-op while already generating.
  Future<void> generate() async {
    if (state.isGenerating) return;

    state = state.copyWith(
      phase: BriefingPhase.fetching,
      progressLabel: 'Leyendo tus fuentes…',
    );

    final fetcher = ref.read(sourceFetcherProvider);
    final extractor = ref.read(sourceContentExtractorProvider);
    final assembler = ref.read(briefingAssemblerProvider);
    final now = ref.read(clockProvider).now();

    // Shared fetch+parse stage (also the background task's) with UI progress.
    final harvester = BriefingHarvester(fetcher: fetcher, extractor: extractor);
    final harvests = await harvester.harvestAll(
      enabledBriefingSources(state.sources),
      onFeed: (i, total) => state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Leyendo fuente ${i + 1} de ${total + 1}…',
      ),
      // Always adds Hacker News (its own adapter), so the comments feature exists.
      onHackerNews: () => state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Leyendo Hacker News…',
      ),
    );

    final assembled = assembler.assemble(harvests, now: now, generatedAt: now);

    if (assembled.isEmpty) {
      state = state.copyWith(
        phase: BriefingPhase.error,
        error:
            'No hay noticias frescas hoy en tus fuentes. Vuelve a intentarlo más tarde.',
      );
      return;
    }

    // Eager, cached translation: render EVERY source into the app language now
    // (in the background scheduler / "Generar ahora" wait), so the reader never
    // taps to translate. Best-effort + per-source isolation — a failing source
    // keeps its original text and the briefing still completes with the rest.
    var briefing = await _translateAll(assembled, extractor);

    // THIRD stage: write a short brief for the items whose feed carried none
    // (Hugging Face ships only a title; Hacker News has no body at all). The
    // laptop never had this gap because it WRITES summaries instead of reading
    // them — this is the phone doing the same. Runs BEFORE the notification,
    // so "tu boletín está listo" is only ever said about a finished briefing.
    briefing = await _writeMissingBriefs(briefing);

    // FOURTH stage: one paragraph per section — the thing the reader reads to
    // decide what to open. Last, so it summarizes the FINAL text of each card
    // (translated, and with the written briefs already in place).
    briefing = await _writeSectionDigests(briefing);
    // Stamp it now that it IS a briefing: the date on screen is the reader's
    // only evidence of whether the automatic run happened.
    briefing = briefing.stampedAt(clock());

    _articleAttempts.clear();
    _commentAttempts.clear();
    state = state.copyWith(
      briefing: briefing,
      phase: BriefingPhase.done,
      progressLabel: null,
      // A fresh briefing clears any stale per-item caches/errors.
      summarizingArticles: const {},
      summarizingComments: const {},
      queuedArticles: const {},
      queuedComments: const {},
      articleFailures: const {},
      commentFailures: const {},
    );

    try {
      await ref
          .read(morningBriefingPreferencesProvider)
          .saveLastBriefing(briefing);
    } catch (_) {
      // In-memory briefing still shown even if persistence failed.
    }
    try {
      await ref.read(briefingNotificationsProvider).showBriefingReady();
    } catch (_) {
      // Notification is best-effort; the briefing is already on screen.
    }
    try {
      await _armTriggers();
    } catch (_) {
      // Scheduling is best-effort; the briefing run itself already succeeded.
    }
  }

  // ---------------------------------------------------------------------------
  // On-demand summaries (per item; run the on-device model only when tapped)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Traducir al ABRIR el boletín (mientras se lee)
  // ---------------------------------------------------------------------------

  /// Translates whatever the OPEN briefing still shows in another language, in
  /// reading order, publishing and persisting each small batch as it lands.
  ///
  /// WHY HERE AND NO LONGER IN THE BACKGROUND (2026-09-06). The 08:08 run used
  /// to translate too, sharing its eight-minute budget with the per-theme
  /// digests; when the budget ran out the translation was the stage that lost,
  /// silently, and the Pixel got a briefing with Spanish summaries over English
  /// headlines announced as "listo". Background translation is also a bet: the
  /// reader sees nothing until he opens, so every headline translated at dawn
  /// is battery spent on text that may never be read. Here there is no bet —
  /// he is looking at it.
  ///
  /// It never blocks the reading. The briefing is already on screen when this
  /// starts; each batch replaces the text of at most
  /// [BriefingTranslationPipeline.readingBatchSize] cards as it arrives, and
  /// each batch is its own job on the shared model queue, so a summary the
  /// reader taps waits for four items, never for the whole briefing.
  ///
  /// Safe to call on every open: articles already translated (or already in the
  /// app language) cost no model call, which is what makes the persisted result
  /// worth writing.
  Future<void> translateOpenBriefing({
    Duration delay = openTranslationGrace,
  }) async {
    if (_disposed || _translating) return;
    if (state.briefing == null) return;
    final run = ++_translationRun;
    _translating = true;
    try {
      if (delay > Duration.zero) {
        _cancelGrace();
        final done = Completer<void>();
        _graceDone = done;
        _graceTimer = Timer(delay, _cancelGrace);
        await done.future;
      }
      if (_disposed || _translationRun != run) return;
      final briefing = state.briefing;
      if (briefing == null) return;

      final engine = ref.read(localLlmEngineProvider);
      final queue = ref.read(llmRequestQueueProvider);
      final pipeline = BriefingTranslationPipeline(
        translator: OnDeviceTranslator(engine),
        extractor: ref.read(sourceContentExtractorProvider),
      );
      EngineFailureDetail? failure;
      var published = false;

      await pipeline.translateInReadingOrder(
        briefing,
        languageCode: _languageCode,
        shouldContinue: () => !_disposed && _translationRun == run,
        onEngineFailure: (detail) => failure = detail,
        // One queue slot per BATCH, not per briefing: the reader's own taps
        // keep getting through while this runs.
        runBatch: (job) => queue.add(job, label: 'briefing:translate'),
        onBatch: (updated) async {
          if (_disposed || _translationRun != run) return updated;
          // Merged onto the CURRENT briefing, article by article: a summary
          // that landed while this batch was decoding must not be overwritten
          // by the snapshot the batch started from.
          final merged = _mergeTranslations(updated);
          published = true;
          state = state.copyWith(phase: state.phase, briefing: merged);
          await _persistBriefing(merged);
          return merged;
        },
      );

      if (_disposed || _translationRun != run) return;
      _noteBackend(engine);
      // Set OR CLEAR, exactly like the generation path: untranslated items with
      // no explanation is the silence this reports, and a stale explanation
      // over text that IS translated is the same lie backwards.
      if (failure != null || published) {
        state = state.copyWith(
          phase: state.phase,
          briefing: state.briefing,
          translationFailure: failure,
          clearTranslationFailure: failure == null,
        );
      }
    } finally {
      _translating = false;
    }
  }

  /// Stops the on-open translation. The batch already inside the model cannot
  /// be un-run — there is no cancel at the native session — but nothing further
  /// is asked for, and a late batch is neither published nor persisted.
  void stopTranslating() {
    _translationRun++;
    _cancelGrace();
  }

  /// Copies the translations carried by [translated] onto the briefing the app
  /// currently holds, leaving every other field (summaries, briefs) as it is.
  OnDeviceBriefing _mergeTranslations(OnDeviceBriefing translated) {
    final held = state.briefing;
    if (held == null) return translated;
    var merged = held;
    for (final a in translated.articles) {
      final title = a.translatedTitle;
      if (title == null || title.trim().isEmpty) continue;
      final current = merged.articleForKey(a.key);
      if (current == null) continue;
      if ((current.translatedTitle ?? '').trim().isNotEmpty) continue;
      merged = merged.replaceArticle(
        current.key,
        current.copyWith(
          translatedTitle: title,
          translatedDescription: a.translatedDescription,
        ),
      );
    }
    return merged;
  }

  /// Fetches [article]'s page and summarizes it on-device (LONGSUM sampling),
  /// caching the result on the article. No-op when already cached or in flight.
  /// Fills in the briefs the feeds did not provide. Best-effort by contract:
  /// a failure here leaves those cards with their hint and never costs the
  /// user the briefing itself.
  Future<OnDeviceBriefing> _writeMissingBriefs(
    OnDeviceBriefing briefing,
  ) async {
    try {
      final writer = BriefingBriefWriter(
        engine: ref.read(localLlmEngineProvider),
        fetcher: ref.read(sourceFetcherProvider),
        extractor: ref.read(sourceContentExtractorProvider),
      );
      return await writer.fillMissing(
        briefing,
        onItem: (i, total) {
          if (_disposed) return;
          state = state.copyWith(
            progressLabel: 'Resumiendo noticias ${i + 1} de $total…',
          );
        },
      );
    } catch (_) {
      return briefing;
    }
  }

  /// Writes the per-section paragraph. Best-effort like every model stage: a
  /// failure leaves the briefing exactly as it came in, with its headlines.
  Future<OnDeviceBriefing> _writeSectionDigests(
    OnDeviceBriefing briefing,
  ) async {
    try {
      return await ref.read(briefingSectionDigestWriterProvider).fillDigests(
        briefing,
        onSection: (i, total) {
          if (_disposed) return;
          state = state.copyWith(
            progressLabel: 'Resumiendo el tema ${i + 1} de $total…',
          );
        },
      );
    } catch (_) {
      return briefing;
    }
  }

  /// The reader tapped "Ver resumen completo".
  ///
  /// The whole job (page fetch + one generation) is submitted to the SHARED
  /// model queue as a single slot, so a second tap cannot interleave with this
  /// one on the phone's only inference session — the bug where the first
  /// summary stopped mid-sentence. Until its slot comes up the article is
  /// reported as QUEUED: accepted and waiting, never running, never dropped.
  Future<void> summarizeArticle(BriefingArticle article) async {
    final briefing = state.briefing;
    if (briefing == null) return;
    final key = article.key;
    final current = briefing.articleForKey(key);
    if (current == null) return;
    if ((current.fullSummary ?? '').isNotEmpty) return;
    if (state.isArticlePending(key)) return;

    _articleAttempts[key] = (_articleAttempts[key] ?? 0) + 1;
    _setArticleQueued(key);
    try {
      await ref.read(llmRequestQueueProvider).add(
        label: 'article:$key',
        onStart: () => _setArticleRunning(key),
        () async {
          try {
            await _ensureModelReady();
            final extract = await _readableArticle(current.url);
            final summary = await _generate(
              _articleSummaryPrompt(title: current.title, content: extract),
            );
            // El artículo VIGENTE, no la foto que se tomó al encolar. Con la
            // foto, un trabajo que termina tarde escribe encima de lo que otro
            // guardó mientras esperaba en la cola: pedir el resumen completo y
            // enseguida el de comentarios borraba el primero al terminar el
            // segundo, y había que ocultarlo y volver a pedirlo.
            final latest = state.briefing?.articleForKey(key) ?? current;
            _cacheArticleUpdate(key, latest.copyWith(fullSummary: summary));
          } on SummaryFailureException catch (e) {
            _setArticleFailure(key, e.failure, detail: e.detail);
          } catch (_) {
            // A failure we cannot attribute to any step: say exactly that,
            // instead of naming the most plausible suspect.
            _setArticleFailure(key, SummaryFailure.unknown);
          }
        },
      );
    } catch (_) {
      // The queue itself refused the job (it never should): say so on the card
      // rather than leave a request that looks accepted and never arrives.
      _setArticleFailure(key, SummaryFailure.unknown);
    }
  }

  /// Loads the on-device model, distinguishing "there is NO model at all" (the
  /// user has to download one; retrying is pointless) from "a model is here but
  /// would not load" (a retry can genuinely work).
  Future<void> _ensureModelReady() async {
    final engine = ref.read(localLlmEngineProvider);
    bool? installed;
    try {
      installed = await engine.isModelInstalled();
    } catch (_) {
      // The device could not even be asked; fall through to the load attempt
      // rather than claiming a missing model we never checked.
      installed = null;
    }
    if (installed == false) {
      throw const SummaryFailureException(SummaryFailure.modelMissing);
    }
    try {
      await engine.load();
    } catch (error) {
      // The headline stays "a model is installed but could not be used" — the
      // reader cannot act on load-vs-generate. The exception rides along so a
      // human CAN, since nothing else on the device can recover it.
      throw SummaryFailureException(
        SummaryFailure.modelUnavailable,
        detail: EngineFailureDetail.from(LlmEngineCall.load, error),
      );
    }
    _noteBackend(engine);
  }

  /// Records whether the model that just loaded is running on a slower fallback
  /// backend, so the panel can explain a summary that suddenly takes minutes.
  /// Read after every successful load: the notice describes the CURRENT load,
  /// and a stale warning about slowness that is over is its own wrong claim.
  void _noteBackend(LocalLlmEngine engine) {
    if (_disposed) return;
    final fallback = engine.usesFallbackBackend;
    if (fallback == state.modelOnFallbackBackend) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      modelOnFallbackBackend: fallback,
    );
  }

  /// The article page's readable text, separating "could not be downloaded"
  /// (transient) from "downloaded, and there is nothing to read" (permanent).
  Future<String> _readableArticle(String url) async {
    final String body;
    try {
      body = await ref.read(sourceFetcherProvider).fetch(url);
    } catch (_) {
      throw const SummaryFailureException(SummaryFailure.pageUnavailable);
    }
    final extract = ref
        .read(sourceContentExtractorProvider)
        .extract(body, url: url);
    if (extract.isEmpty) {
      throw const SummaryFailureException(SummaryFailure.pageUnreadable);
    }
    return extract.text;
  }

  /// One LONGSUM generation, with an empty answer reported as its own cause.
  Future<String> _generate(String prompt) async {
    final GenerationResult result;
    try {
      result = await ref
          .read(localLlmEngineProvider)
          .generate(
            prompt,
            temperature: longsumTemperature,
            topK: longsumTopK,
            topP: longsumTopP,
          );
    } catch (error) {
      throw SummaryFailureException(
        SummaryFailure.modelUnavailable,
        detail: EngineFailureDetail.from(LlmEngineCall.generate, error),
      );
    }
    final text = result.text.trim();
    if (text.isEmpty) {
      throw const SummaryFailureException(SummaryFailure.emptyGeneration);
    }
    return text;
  }

  /// Fetches [article]'s HN comments thread and summarizes it on-device
  /// (LONGSUM), caching the result. HN items only; no-op when cached/in flight.
  Future<void> summarizeComments(BriefingArticle article) async {
    final briefing = state.briefing;
    if (briefing == null) return;
    final key = article.key;
    final current = briefing.articleForKey(key);
    if (current == null || !current.isHackerNews) return;
    if ((current.commentsSummary ?? '').isNotEmpty) return;
    if (state.isCommentsPending(key)) return;

    _commentAttempts[key] = (_commentAttempts[key] ?? 0) + 1;
    _setCommentsQueued(key);
    try {
      await ref.read(llmRequestQueueProvider).add(
        label: 'comments:$key',
        onStart: () => _setCommentsRunning(key),
        () async {
          try {
            await _ensureModelReady();
            final comments = await _readableComments(current.hnObjectId);
            final summary = await _generate(_commentsSummaryPrompt(comments));
            // El vigente, por lo mismo que arriba: este es justo el trabajo
            // que borraba el resumen completo al terminar después.
            final latest = state.briefing?.articleForKey(key) ?? current;
            _cacheCommentsUpdate(
              key,
              latest.copyWith(commentsSummary: summary),
            );
          } on SummaryFailureException catch (e) {
            _setCommentsFailure(key, e.failure, detail: e.detail);
          } catch (_) {
            _setCommentsFailure(key, SummaryFailure.unknown);
          }
        },
      );
    } catch (_) {
      _setCommentsFailure(key, SummaryFailure.unknown);
    }
  }

  /// The HN thread's comment text: a thread that could not be downloaded is
  /// transient; a thread with no comments in it is simply nothing to summarize.
  Future<String> _readableComments(String? hnObjectId) async {
    final String body;
    try {
      body = await ref
          .read(sourceFetcherProvider)
          .fetch('$hnItemUrlPrefix$hnObjectId');
    } catch (_) {
      throw const SummaryFailureException(SummaryFailure.pageUnavailable);
    }
    final comments = ref
        .read(sourceContentExtractorProvider)
        .extractHnComments(body);
    if (comments.trim().isEmpty) {
      throw const SummaryFailureException(SummaryFailure.commentsMissing);
    }
    return comments;
  }

  // ---------------------------------------------------------------------------
  // Eager per-source title/brief translation (at generation, cached)
  // ---------------------------------------------------------------------------

  /// Translates EVERY source's titles + briefs into the app language up front,
  /// so the reader never has to tap to translate. Delegates to the shared
  /// [BriefingTranslationPipeline] (also the background task's), adding only
  /// the UI progress label. Never throws — a catastrophic failure degrades the
  /// whole briefing to its original (untranslated) text.
  Future<OnDeviceBriefing> _translateAll(
    OnDeviceBriefing assembled,
    SourceContentExtractor extractor,
  ) async {
    final engine = ref.read(localLlmEngineProvider);
    final pipeline = BriefingTranslationPipeline(
      translator: OnDeviceTranslator(engine),
      extractor: extractor,
    );
    EngineFailureDetail? failure;
    final translated = await pipeline.translateAll(
      assembled,
      languageCode: _languageCode,
      onSource: (i, total) => state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Traduciendo noticias ${i + 1} de $total…',
      ),
      onEngineFailure: (detail) => failure = detail,
    );
    if (!_disposed) {
      // Set OR CLEAR: a run that translated fine must not leave the previous
      // run's explanation standing over items that are now translated.
      state = state.copyWith(
        phase: state.phase,
        briefing: state.briefing,
        translationFailure: failure,
        clearTranslationFailure: failure == null,
      );
      _noteBackend(engine);
    }
    return translated;
  }

  // --- per-item state transitions -------------------------------------------

  /// Accepted, waiting for the shared model queue: the card says "en cola".
  void _setArticleQueued(String key) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedArticles: {...state.queuedArticles, key},
      articleFailures: {...state.articleFailures}..remove(key),
    );
  }

  /// The queue reached this job: waiting → running.
  void _setArticleRunning(String key) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedArticles: {...state.queuedArticles}..remove(key),
      summarizingArticles: {...state.summarizingArticles, key},
    );
  }

  void _cacheArticleUpdate(String key, BriefingArticle updated) {
    if (_disposed) return;
    _articleAttempts.remove(key);
    final briefing = state.briefing?.replaceArticle(key, updated);
    state = state.copyWith(
      phase: state.phase,
      briefing: briefing,
      queuedArticles: {...state.queuedArticles}..remove(key),
      summarizingArticles: {...state.summarizingArticles}..remove(key),
    );
    _persistBriefing(briefing);
  }

  void _setArticleFailure(
    String key,
    SummaryFailure failure, {
    EngineFailureDetail? detail,
  }) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedArticles: {...state.queuedArticles}..remove(key),
      summarizingArticles: {...state.summarizingArticles}..remove(key),
      articleFailures: {
        ...state.articleFailures,
        key: SummaryAttemptFailure(
          failure: failure,
          attempt: _articleAttempts[key] ?? 1,
          detail: detail,
        ),
      },
    );
  }

  void _setCommentsQueued(String key) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedComments: {...state.queuedComments, key},
      commentFailures: {...state.commentFailures}..remove(key),
    );
  }

  void _setCommentsRunning(String key) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedComments: {...state.queuedComments}..remove(key),
      summarizingComments: {...state.summarizingComments, key},
    );
  }

  void _cacheCommentsUpdate(String key, BriefingArticle updated) {
    if (_disposed) return;
    _commentAttempts.remove(key);
    final briefing = state.briefing?.replaceArticle(key, updated);
    state = state.copyWith(
      phase: state.phase,
      briefing: briefing,
      queuedComments: {...state.queuedComments}..remove(key),
      summarizingComments: {...state.summarizingComments}..remove(key),
    );
    _persistBriefing(briefing);
  }

  void _setCommentsFailure(
    String key,
    SummaryFailure failure, {
    EngineFailureDetail? detail,
  }) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedComments: {...state.queuedComments}..remove(key),
      summarizingComments: {...state.summarizingComments}..remove(key),
      commentFailures: {
        ...state.commentFailures,
        key: SummaryAttemptFailure(
          failure: failure,
          attempt: _commentAttempts[key] ?? 1,
          detail: detail,
        ),
      },
    );
  }

  Future<void> _persistBriefing(OnDeviceBriefing? briefing) async {
    if (briefing == null) return;
    try {
      await ref
          .read(morningBriefingPreferencesProvider)
          .saveLastBriefing(briefing);
    } catch (_) {
      // Best-effort: the cached summary is still shown in memory.
    }
  }

  // --- prompts / language ----------------------------------------------------

  /// The current output language (i18n slice). On-demand summaries are written
  /// in this language, translating foreign-language sources into it — which is
  /// why the feed-native title/description are kept as-is on the card.
  String get _languageCode => ref.read(appLanguageCodeProvider);

  String _articleSummaryPrompt({
    required String title,
    required String content,
  }) => switch (_languageCode) {
    'en' =>
      'Summarize the following news article in 3 to 5 sentences, in clear English. '
          'If it is in another language, translate it into English. '
          'Return only the summary, with no headings or bullet points.\n\n'
          'Title: $title\n\nContent:\n$content',
    _ =>
      'Resume en 3 a 5 frases, en español neutro y claro, el siguiente artículo de '
          'noticias. Si está en otro idioma, tradúcelo al español. '
          'Devuelve solo el resumen, sin encabezados ni viñetas.\n\n'
          'Título: $title\n\nContenido:\n$content',
  };

  String _commentsSummaryPrompt(String comments) => switch (_languageCode) {
    'en' =>
      'Summarize these Hacker News comments in 3 to 5 sentences, in English: the main '
          'opinions and the points of agreement or disagreement. Return only the summary.\n\n$comments',
    _ =>
      'Resume estos comentarios de Hacker News en 3 a 5 frases, en español neutro: las '
          'opiniones principales y los puntos de acuerdo o desacuerdo. Devuelve solo el '
          'resumen.\n\n$comments',
  };
}

final morningBriefingNotifierProvider =
    NotifierProvider<MorningBriefingNotifier, MorningBriefingState>(
      MorningBriefingNotifier.new,
    );
