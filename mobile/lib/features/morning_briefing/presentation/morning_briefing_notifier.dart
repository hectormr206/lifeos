import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/clock/clock.dart';
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
  });

  /// Configured news-source URLs (the user adds/removes these).
  final List<String> sources;

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

  bool get isGenerating => phase == BriefingPhase.fetching;

  bool isSummarizingArticle(String key) => summarizingArticles.contains(key);
  bool isSummarizingComments(String key) => summarizingComments.contains(key);

  /// Whether the article's full summary was accepted and is waiting its turn.
  bool isQueuedArticle(String key) => queuedArticles.contains(key);

  /// Whether the article's comments summary was accepted and is waiting.
  bool isQueuedComments(String key) => queuedComments.contains(key);

  /// Running OR waiting — the guard against enqueuing the same article twice.
  bool isArticlePending(String key) => isSummarizingArticle(key) || isQueuedArticle(key);

  /// Running OR waiting, for the comments summary.
  bool isCommentsPending(String key) => isSummarizingComments(key) || isQueuedComments(key);

  MorningBriefingState copyWith({
    List<String>? sources,
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
  }) =>
      MorningBriefingState(
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

  /// Injectable clock for the schedule/auto-run logic (production uses the real
  /// clock). Freshness uses [clockProvider] instead (the device-timezone seam).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  /// LONGSUM tuned sampling for gemma-4-E2B (the summarization role): lower
  /// temperature for factual, non-divergent summaries. Passed as per-call
  /// overrides to [LocalLlmEngine.generate] for the on-demand summaries.
  static const double longsumTemperature = 0.2;
  static const int longsumTopK = 20;
  static const double longsumTopP = 0.9;

  @override
  MorningBriefingState build() {
    ref.onDispose(() {
      _disposed = true;
      _autoRunTimer?.cancel();
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
      state = state.copyWith(sources: sources, briefing: last, schedule: schedule);
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // keep the safe empty default rather than crashing.
    }
    await _armTriggers();
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
      return (await ref.read(effectiveTimezoneProvider.future)).overrideLocation;
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
    await backgroundWork.scheduleOneOff(next.difference(base));
    if (_disposed) return;
    await scheduler.scheduleReminder(next.add(kBriefingReminderGrace));
    if (_disposed) return;
    _autoRunTimer = Timer(next.difference(base), _onAutoRunTimer);
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

    state = state.copyWith(phase: BriefingPhase.fetching, progressLabel: 'Leyendo tus fuentes…');

    final fetcher = ref.read(sourceFetcherProvider);
    final extractor = ref.read(sourceContentExtractorProvider);
    final assembler = ref.read(briefingAssemblerProvider);
    final now = ref.read(clockProvider).now();

    // Shared fetch+parse stage (also the background task's) with UI progress.
    final harvester = BriefingHarvester(fetcher: fetcher, extractor: extractor);
    final harvests = await harvester.harvestAll(
      state.sources,
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
        error: 'No hay noticias frescas hoy en tus fuentes. Vuelve a intentarlo más tarde.',
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
      await ref.read(morningBriefingPreferencesProvider).saveLastBriefing(briefing);
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

  /// Fetches [article]'s page and summarizes it on-device (LONGSUM sampling),
  /// caching the result on the article. No-op when already cached or in flight.
  /// Fills in the briefs the feeds did not provide. Best-effort by contract:
  /// a failure here leaves those cards with their hint and never costs the
  /// user the briefing itself.
  Future<OnDeviceBriefing> _writeMissingBriefs(OnDeviceBriefing briefing) async {
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
          state = state.copyWith(progressLabel: 'Resumiendo noticias ${i + 1} de $total…');
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
            _cacheArticleUpdate(key, current.copyWith(fullSummary: summary));
          } on SummaryFailureException catch (e) {
            _setArticleFailure(key, e.failure);
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
    } catch (_) {
      throw const SummaryFailureException(SummaryFailure.modelUnavailable);
    }
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
    final extract = ref.read(sourceContentExtractorProvider).extract(body, url: url);
    if (extract.isEmpty) {
      throw const SummaryFailureException(SummaryFailure.pageUnreadable);
    }
    return extract.text;
  }

  /// One LONGSUM generation, with an empty answer reported as its own cause.
  Future<String> _generate(String prompt) async {
    final GenerationResult result;
    try {
      result = await ref.read(localLlmEngineProvider).generate(
            prompt,
            temperature: longsumTemperature,
            topK: longsumTopK,
            topP: longsumTopP,
          );
    } catch (_) {
      throw const SummaryFailureException(SummaryFailure.modelUnavailable);
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
            _cacheCommentsUpdate(key, current.copyWith(commentsSummary: summary));
          } on SummaryFailureException catch (e) {
            _setCommentsFailure(key, e.failure);
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
      body = await ref.read(sourceFetcherProvider).fetch('$hnItemUrlPrefix$hnObjectId');
    } catch (_) {
      throw const SummaryFailureException(SummaryFailure.pageUnavailable);
    }
    final comments = ref.read(sourceContentExtractorProvider).extractHnComments(body);
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
    final pipeline = BriefingTranslationPipeline(
      translator: OnDeviceTranslator(ref.read(localLlmEngineProvider)),
      extractor: extractor,
    );
    return pipeline.translateAll(
      assembled,
      languageCode: _languageCode,
      onSource: (i, total) => state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Traduciendo noticias ${i + 1} de $total…',
      ),
    );
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

  void _setArticleFailure(String key, SummaryFailure failure) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedArticles: {...state.queuedArticles}..remove(key),
      summarizingArticles: {...state.summarizingArticles}..remove(key),
      articleFailures: {
        ...state.articleFailures,
        key: SummaryAttemptFailure(failure: failure, attempt: _articleAttempts[key] ?? 1),
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

  void _setCommentsFailure(String key, SummaryFailure failure) {
    if (_disposed) return;
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      queuedComments: {...state.queuedComments}..remove(key),
      summarizingComments: {...state.summarizingComments}..remove(key),
      commentFailures: {
        ...state.commentFailures,
        key: SummaryAttemptFailure(failure: failure, attempt: _commentAttempts[key] ?? 1),
      },
    );
  }

  Future<void> _persistBriefing(OnDeviceBriefing? briefing) async {
    if (briefing == null) return;
    try {
      await ref.read(morningBriefingPreferencesProvider).saveLastBriefing(briefing);
    } catch (_) {
      // Best-effort: the cached summary is still shown in memory.
    }
  }

  // --- prompts / language ----------------------------------------------------

  /// The current output language (i18n slice). On-demand summaries are written
  /// in this language, translating foreign-language sources into it — which is
  /// why the feed-native title/description are kept as-is on the card.
  String get _languageCode => ref.read(appLanguageCodeProvider);

  String _articleSummaryPrompt({required String title, required String content}) =>
      switch (_languageCode) {
        'en' => 'Summarize the following news article in 3 to 5 sentences, in clear English. '
            'If it is in another language, translate it into English. '
            'Return only the summary, with no headings or bullet points.\n\n'
            'Title: $title\n\nContent:\n$content',
        _ => 'Resume en 3 a 5 frases, en español neutro y claro, el siguiente artículo de '
            'noticias. Si está en otro idioma, tradúcelo al español. '
            'Devuelve solo el resumen, sin encabezados ni viñetas.\n\n'
            'Título: $title\n\nContenido:\n$content',
      };

  String _commentsSummaryPrompt(String comments) => switch (_languageCode) {
        'en' => 'Summarize these Hacker News comments in 3 to 5 sentences, in English: the main '
            'opinions and the points of agreement or disagreement. Return only the summary.\n\n$comments',
        _ => 'Resume estos comentarios de Hacker News en 3 a 5 frases, en español neutro: las '
            'opiniones principales y los puntos de acuerdo o desacuerdo. Devuelve solo el '
            'resumen.\n\n$comments',
      };
}

final morningBriefingNotifierProvider =
    NotifierProvider<MorningBriefingNotifier, MorningBriefingState>(MorningBriefingNotifier.new);
