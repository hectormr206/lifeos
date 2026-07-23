import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock/clock.dart';
import '../../../l10n/locale_providers.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../data/source_content_extractor.dart';
import '../domain/briefing_assembler.dart';
import '../domain/briefing_schedule.dart';
import '../domain/morning_briefing.dart';
import '../domain/source_fetcher.dart';
import 'morning_briefing_providers.dart';

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

/// Hacker News front-page candidates via the Algolia JSON API. Fetched with the
/// same browser-like [SourceFetcher] as the feeds; parsed by
/// [SourceContentExtractor.parseHackerNews]. Each item keeps its `objectID`, so
/// the on-demand "Ver resumen de comentarios" action can fetch the thread.
const String hnFrontPageUrl = 'https://hn.algolia.com/api/v1/search?tags=front_page';

/// The HN Algolia single-item (comments thread) endpoint prefix.
const String hnItemUrlPrefix = 'https://hn.algolia.com/api/v1/items/';

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
    this.articleErrors = const {},
    this.commentErrors = const {},
    this.translatingSources = const {},
    this.translatedSources = const {},
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

  /// Per-article on-demand full-summary error messages (keyed by article key).
  final Map<String, String> articleErrors;

  /// Per-article on-demand comments-summary error messages.
  final Map<String, String> commentErrors;

  /// Source names whose titles/briefs are being batch-translated right now (the
  /// accordion shows a subtle "Traduciendo…" state while this is set).
  final Set<String> translatingSources;

  /// Source names already handled by the lazy translator (translated, skipped
  /// as same-language, or failed-and-fell-back) — so a re-expand never re-runs
  /// the model. Reset on every fresh [generate].
  final Set<String> translatedSources;

  bool get isGenerating => phase == BriefingPhase.fetching;

  bool isSummarizingArticle(String key) => summarizingArticles.contains(key);
  bool isSummarizingComments(String key) => summarizingComments.contains(key);
  bool isTranslatingSource(String name) => translatingSources.contains(name);

  MorningBriefingState copyWith({
    List<String>? sources,
    OnDeviceBriefing? briefing,
    BriefingSchedule? schedule,
    BriefingPhase? phase,
    String? progressLabel,
    String? error,
    Set<String>? summarizingArticles,
    Set<String>? summarizingComments,
    Map<String, String>? articleErrors,
    Map<String, String>? commentErrors,
    Set<String>? translatingSources,
    Set<String>? translatedSources,
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
        articleErrors: articleErrors ?? this.articleErrors,
        commentErrors: commentErrors ?? this.commentErrors,
        translatingSources: translatingSources ?? this.translatingSources,
        translatedSources: translatedSources ?? this.translatedSources,
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

  /// Light sampling for the batched per-source TITLE/BRIEF translation: a low
  /// temperature keeps the rendering faithful (translate, don't rewrite) while
  /// staying above the degenerate-to-empty floor.
  static const double translateTemperature = 0.3;
  static const int translateTopK = 20;
  static const double translateTopP = 0.9;

  @override
  MorningBriefingState build() {
    ref.onDispose(() => _autoRunTimer?.cancel());
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

  /// (Re)arms BOTH triggers (OS reminder + in-app timer) for the current
  /// schedule. Disabled → both cancelled. One-shot: every start/resume/run
  /// re-arms for the NEXT occurrence.
  Future<void> _armTriggers() async {
    _autoRunTimer?.cancel();
    _autoRunTimer = null;
    final scheduler = ref.read(briefingSchedulerProvider);
    final schedule = state.schedule;
    if (!schedule.enabled) {
      await scheduler.cancelReminder();
      return;
    }
    final now = clock();
    final next = schedule.nextRun(now, lastGeneratedAt: state.briefing?.generatedAt);
    await scheduler.scheduleReminder(next);
    _autoRunTimer = Timer(next.difference(now), _onAutoRunTimer);
  }

  Future<void> _onAutoRunTimer() async {
    await maybeAutoGenerate();
  }

  /// Entry point for every trigger path: runs [generate] IF the schedule says a
  /// run is due AND today's briefing does not exist yet. Always re-arms after.
  Future<void> maybeAutoGenerate() async {
    await ready;
    if (state.isGenerating) return;
    final due = state.schedule.shouldRunNow(
      clock(),
      lastGeneratedAt: state.briefing?.generatedAt,
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

    final harvests = <SourceHarvest>[];
    final feeds = state.sources;
    for (var i = 0; i < feeds.length; i++) {
      state = state.copyWith(
        phase: BriefingPhase.fetching,
        progressLabel: 'Leyendo fuente ${i + 1} de ${feeds.length + 1}…',
      );
      harvests.add(await _harvestFeed(feeds[i], fetcher, extractor));
    }
    // Always add Hacker News (its own adapter), so the comments feature exists.
    state = state.copyWith(phase: BriefingPhase.fetching, progressLabel: 'Leyendo Hacker News…');
    harvests.add(await _harvestHackerNews(fetcher, extractor));

    final briefing = assembler.assemble(harvests, now: now, generatedAt: now);

    if (briefing.isEmpty) {
      state = state.copyWith(
        phase: BriefingPhase.error,
        error: 'No hay noticias frescas hoy en tus fuentes. Vuelve a intentarlo más tarde.',
      );
      return;
    }

    state = state.copyWith(
      briefing: briefing,
      phase: BriefingPhase.done,
      progressLabel: null,
      // A fresh briefing clears any stale per-item caches/errors.
      summarizingArticles: const {},
      summarizingComments: const {},
      articleErrors: const {},
      commentErrors: const {},
      translatingSources: const {},
      translatedSources: const {},
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

  Future<SourceHarvest> _harvestFeed(
    String url,
    SourceFetcher fetcher,
    SourceContentExtractor extractor,
  ) async {
    try {
      final body = await fetcher.fetch(url);
      final feed = extractor.parseFeed(body, url: url);
      final name = feed.sourceTitle.trim().isEmpty ? _hostLabel(url) : feed.sourceTitle.trim();
      return SourceHarvest(name: name, items: feed.items);
    } catch (_) {
      return SourceHarvest(name: _hostLabel(url), failed: true);
    }
  }

  Future<SourceHarvest> _harvestHackerNews(
    SourceFetcher fetcher,
    SourceContentExtractor extractor,
  ) async {
    try {
      final body = await fetcher.fetch(hnFrontPageUrl);
      final feed = extractor.parseHackerNews(body);
      return SourceHarvest(name: feed.sourceTitle, items: feed.items);
    } catch (_) {
      return SourceHarvest(name: 'Hacker News', failed: true);
    }
  }

  String _hostLabel(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }

  // ---------------------------------------------------------------------------
  // On-demand summaries (per item; run the on-device model only when tapped)
  // ---------------------------------------------------------------------------

  /// Fetches [article]'s page and summarizes it on-device (LONGSUM sampling),
  /// caching the result on the article. No-op when already cached or in flight.
  Future<void> summarizeArticle(BriefingArticle article) async {
    final briefing = state.briefing;
    if (briefing == null) return;
    final key = article.key;
    final current = briefing.articleForKey(key);
    if (current == null) return;
    if ((current.fullSummary ?? '').isNotEmpty) return;
    if (state.isSummarizingArticle(key)) return;

    _setArticlePending(key);
    try {
      await ref.read(localLlmEngineProvider).load();
      final fetcher = ref.read(sourceFetcherProvider);
      final extractor = ref.read(sourceContentExtractorProvider);
      final body = await fetcher.fetch(current.url);
      final extract = extractor.extract(body, url: current.url);
      if (extract.isEmpty) throw Exception('sin contenido legible');
      final result = await ref.read(localLlmEngineProvider).generate(
            _articleSummaryPrompt(title: current.title, content: extract.text),
            temperature: longsumTemperature,
            topK: longsumTopK,
            topP: longsumTopP,
          );
      final summary = result.text.trim();
      if (summary.isEmpty) throw Exception('resumen vacío');
      _cacheArticleUpdate(key, current.copyWith(fullSummary: summary));
    } catch (_) {
      _setArticleError(key, _summaryErrorMessage);
    }
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
    if (state.isSummarizingComments(key)) return;

    _setCommentsPending(key);
    try {
      await ref.read(localLlmEngineProvider).load();
      final fetcher = ref.read(sourceFetcherProvider);
      final extractor = ref.read(sourceContentExtractorProvider);
      final body = await fetcher.fetch('$hnItemUrlPrefix${current.hnObjectId}');
      final comments = extractor.extractHnComments(body);
      if (comments.trim().isEmpty) throw Exception('sin comentarios');
      final result = await ref.read(localLlmEngineProvider).generate(
            _commentsSummaryPrompt(comments),
            temperature: longsumTemperature,
            topK: longsumTopK,
            topP: longsumTopP,
          );
      final summary = result.text.trim();
      if (summary.isEmpty) throw Exception('resumen vacío');
      _cacheCommentsUpdate(key, current.copyWith(commentsSummary: summary));
    } catch (_) {
      _setCommentsError(key, _commentsErrorMessage);
    }
  }

  // ---------------------------------------------------------------------------
  // Lazy per-source title/brief translation (on first accordion expand)
  // ---------------------------------------------------------------------------

  /// Translates one source's titles (+ briefs) into the app language with ONE
  /// batched on-device call, caching the results on the articles. Called when a
  /// source's accordion expands for the first time. No-op when already
  /// translating/handled, when the source's items already look like the target
  /// language (cheap detection → skipped), or when a prior run already cached a
  /// translation (instant re-expand, incl. across sessions). On any failure the
  /// feed-native title is kept (never blank) and the source is marked handled.
  Future<void> translateSource(String sourceName) async {
    final briefing = state.briefing;
    if (briefing == null) return;
    if (state.isTranslatingSource(sourceName)) return;
    if (state.translatedSources.contains(sourceName)) return;

    final articles = briefing.articles.where((a) => a.sourceName == sourceName).toList();
    if (articles.isEmpty) {
      _markSourceHandled(sourceName);
      return;
    }
    // A cached translation from a prior run (this session or a reloaded cache)
    // makes the re-expand instant — nothing to do.
    if (articles.any((a) => (a.translatedTitle ?? '').isNotEmpty)) {
      _markSourceHandled(sourceName);
      return;
    }
    // Cheap same-language detection: skip translating feeds already in the
    // target language.
    final sample = articles.map((a) => '${a.title} ${a.description}').join('\n');
    if (_looksTargetLanguage(sample, _languageCode)) {
      _markSourceHandled(sourceName);
      return;
    }

    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      translatingSources: {...state.translatingSources, sourceName},
    );
    try {
      await ref.read(localLlmEngineProvider).load();
      final result = await ref.read(localLlmEngineProvider).generate(
            _translatePrompt(articles),
            temperature: translateTemperature,
            topK: translateTopK,
            topP: translateTopP,
          );
      final parsed = _parseTranslation(result.text);
      var updated = state.briefing ?? briefing;
      for (var i = 0; i < articles.length; i++) {
        final current = updated.articleForKey(articles[i].key);
        if (current == null) continue;
        final entry = parsed[i + 1];
        if (entry == null) continue;
        final t = entry.$1.trim();
        final d = entry.$2?.trim() ?? '';
        if (t.isEmpty) continue; // keep native title on a missing line
        updated = updated.replaceArticle(
          current.key,
          current.copyWith(
            translatedTitle: t,
            // Only translate a brief the item actually has.
            translatedDescription: current.description.isNotEmpty && d.isNotEmpty ? d : null,
          ),
        );
      }
      state = state.copyWith(
        phase: state.phase,
        briefing: updated,
        translatingSources: {...state.translatingSources}..remove(sourceName),
        translatedSources: {...state.translatedSources, sourceName},
      );
      _persistBriefing(updated);
    } catch (_) {
      // Fallback: keep the feed-native titles, mark handled so we don't loop.
      state = state.copyWith(
        phase: state.phase,
        briefing: state.briefing,
        translatingSources: {...state.translatingSources}..remove(sourceName),
        translatedSources: {...state.translatedSources, sourceName},
      );
    }
  }

  void _markSourceHandled(String sourceName) {
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      translatedSources: {...state.translatedSources, sourceName},
    );
  }

  /// Cheap language guess for the same-language skip. Returns true when [text]
  /// already looks like [code]'s language, so no translation is needed. Biased
  /// to translate when there is no positive evidence of the target language
  /// (short English HN headlines have no Spanish signal → translate to es).
  static bool _looksTargetLanguage(String text, String code) {
    final lower = text.toLowerCase();
    if (lower.trim().isEmpty) return true; // nothing to translate
    final hasEsChars = RegExp(r'[áéíóúñ¿¡]').hasMatch(lower);
    final words = lower.split(RegExp(r'[^a-z]+')).where((w) => w.length > 1).toList();
    var es = 0, en = 0;
    for (final w in words) {
      if (_esStop.contains(w)) es++;
      if (_enStop.contains(w)) en++;
    }
    if (code == 'en') return !hasEsChars && en > es;
    // Default target is Spanish.
    return hasEsChars || es > en;
  }

  static const Set<String> _esStop = {
    'de', 'la', 'el', 'que', 'en', 'los', 'del', 'las', 'por', 'una', 'para', 'con', 'su', 'al',
    'un', 'como', 'más', 'pero', 'sus', 'le', 'ya', 'este', 'sí', 'porque', 'esta', 'son',
  };
  static const Set<String> _enStop = {
    'the', 'of', 'and', 'to', 'in', 'for', 'is', 'on', 'with', 'that', 'it', 'as', 'are', 'at',
    'by', 'an', 'be', 'this', 'from', 'or', 'was', 'how', 'why', 'new', 'your',
  };

  /// Builds the batched translation prompt: a numbered list of `title ||| brief`
  /// (the ` ||| brief` omitted when the item has no brief), asking the model to
  /// preserve the numbering + separator so [_parseTranslation] can map results
  /// back to items.
  String _translatePrompt(List<BriefingArticle> articles) {
    final target = _languageCode == 'en' ? 'English' : 'neutral Spanish';
    final buffer = StringBuffer();
    for (var i = 0; i < articles.length; i++) {
      final a = articles[i];
      final line = a.description.isNotEmpty ? '${a.title} ||| ${a.description}' : a.title;
      buffer.writeln('${i + 1}. $line');
    }
    return 'Translate each of the following news headlines to $target. '
        'Keep the exact same numbering (one item per line) and, when a line contains '
        'the " ||| " separator, translate BOTH sides and keep the " ||| " between them. '
        'Translate only the text, do not add anything.\n\n$buffer';
  }

  /// Parses the model's numbered response into `{index: (title, brief?)}`. Lines
  /// that do not match the `N. …` shape are ignored so a chatty model never
  /// corrupts the mapping (missing items fall back to the feed-native title).
  static Map<int, (String, String?)> _parseTranslation(String out) {
    final map = <int, (String, String?)>{};
    final lineNo = RegExp(r'^\s*(\d+)[.)]\s*(.*)$');
    for (final raw in out.split('\n')) {
      final m = lineNo.firstMatch(raw.trim());
      if (m == null) continue;
      final idx = int.parse(m.group(1)!);
      final rest = m.group(2)!.trim();
      if (rest.isEmpty) continue;
      final parts = rest.split('|||');
      final title = parts[0].trim();
      final brief = parts.length > 1 ? parts.sublist(1).join('|||').trim() : null;
      map[idx] = (title, brief);
    }
    return map;
  }

  // --- per-item state transitions -------------------------------------------

  void _setArticlePending(String key) {
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      summarizingArticles: {...state.summarizingArticles, key},
      articleErrors: {...state.articleErrors}..remove(key),
    );
  }

  void _cacheArticleUpdate(String key, BriefingArticle updated) {
    final briefing = state.briefing?.replaceArticle(key, updated);
    state = state.copyWith(
      phase: state.phase,
      briefing: briefing,
      summarizingArticles: {...state.summarizingArticles}..remove(key),
    );
    _persistBriefing(briefing);
  }

  void _setArticleError(String key, String message) {
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      summarizingArticles: {...state.summarizingArticles}..remove(key),
      articleErrors: {...state.articleErrors, key: message},
    );
  }

  void _setCommentsPending(String key) {
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      summarizingComments: {...state.summarizingComments, key},
      commentErrors: {...state.commentErrors}..remove(key),
    );
  }

  void _cacheCommentsUpdate(String key, BriefingArticle updated) {
    final briefing = state.briefing?.replaceArticle(key, updated);
    state = state.copyWith(
      phase: state.phase,
      briefing: briefing,
      summarizingComments: {...state.summarizingComments}..remove(key),
    );
    _persistBriefing(briefing);
  }

  void _setCommentsError(String key, String message) {
    state = state.copyWith(
      phase: state.phase,
      briefing: state.briefing,
      summarizingComments: {...state.summarizingComments}..remove(key),
      commentErrors: {...state.commentErrors, key: message},
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

  String get _summaryErrorMessage => switch (_languageCode) {
        'en' => 'Could not generate the summary. Try again.',
        _ => 'No se pudo generar el resumen. Inténtalo de nuevo.',
      };

  String get _commentsErrorMessage => switch (_languageCode) {
        'en' => 'Could not summarize the comments. Try again.',
        _ => 'No se pudo resumir los comentarios. Inténtalo de nuevo.',
      };

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
