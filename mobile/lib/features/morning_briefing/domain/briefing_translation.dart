import '../../local_model/domain/engine_failure_detail.dart';
import '../../local_model/domain/on_device_translator.dart';
import '../data/source_content_extractor.dart';
import 'morning_briefing.dart';

/// Wraps one batched model call so the caller can serialize it (the shared
/// [LlmRequestQueue] in the app). Defaults to running the job inline.
typedef BriefingTranslationBatchRunner =
    Future<List<String?>> Function(Future<List<String?>> Function() job);

/// Eager per-source title/brief translation of an assembled briefing — the
/// SECOND stage of the pipeline, after fetch+assemble.
///
/// Extracted from the notifier so the SAME translation (per-article
/// same-language skip, `title ||| brief` packing, per-slot fallback, source
/// de-duplication) runs
/// both in the foreground (`MorningBriefingNotifier.generate`, with a
/// progress-label callback) and in the headless WorkManager background task.
///
/// Contract: NEVER throws — a catastrophic failure returns the briefing it was
/// given (original, untranslated text); a per-source failure keeps that
/// source's native text while the rest are still translated.
class BriefingTranslationPipeline {
  const BriefingTranslationPipeline({
    required this.translator,
    required this.extractor,
  });

  final OnDeviceTranslator translator;
  final SourceContentExtractor extractor;

  /// Light sampling for the batched per-source TITLE/BRIEF translation: a low
  /// temperature keeps the rendering faithful (translate, don't rewrite) while
  /// staying above the degenerate-to-empty floor.
  static const double translateTemperature = 0.3;
  static const int translateTopK = 20;
  static const double translateTopP = 0.9;

  /// Items published at a time by [translateInReadingOrder] — the translator's
  /// own batch size, so one published batch is exactly one model call.
  static const int readingBatchSize = OnDeviceTranslator.maxItemsPerBatch;

  /// Translates EVERY source's titles + briefs into [languageCode] up front,
  /// one batched model call per source, with PER-SOURCE isolation. [onSource]
  /// fires before each source's model call (UI-progress seam).
  ///
  /// [onEngineFailure] fires AT MOST ONCE for the whole briefing, with the real
  /// exception behind an engine that could not run. Untranslated items with no
  /// explanation is the exact silence this reports: the model failure that
  /// stops a summary stops every translation too, and the reader used to see
  /// only the symptom.
  Future<OnDeviceBriefing> translateAll(
    OnDeviceBriefing assembled, {
    required String languageCode,
    void Function(int index, int total)? onSource,
    void Function(EngineFailureDetail detail)? onEngineFailure,
  }) async {
    var reported = false;
    void report(EngineFailureDetail detail) {
      if (reported) return;
      reported = true;
      onEngineFailure?.call(detail);
    }

    try {
      // DE-DUPLICATED by name: [OnDeviceBriefing.groups] merges only
      // CONSECUTIVE same-source runs, so a source name split across
      // non-adjacent runs (feed+atom of one site, or two empty-title feeds on
      // the same host label) would appear twice — and since [translateSource]
      // selects by name across the WHOLE briefing, that meant a second FULL
      // model call over the same articles. A Set keeps first-seen order while
      // translating each source exactly once.
      final sourceNames = assembled.groups
          .map((g) => g.sourceName)
          .toSet()
          .toList(growable: false);
      var briefing = assembled;
      for (var i = 0; i < sourceNames.length; i++) {
        onSource?.call(i, sourceNames.length);
        briefing = await translateSource(
          briefing,
          sourceNames[i],
          languageCode,
          onEngineFailure: report,
        );
      }
      return briefing;
    } catch (_) {
      // Any unexpected failure: keep the assembled (original-language) briefing.
      return assembled;
    }
  }

  /// Translates one source's articles inside [briefing], returning an updated
  /// briefing. Articles ALREADY in the target language are skipped one by one
  /// (a source with none left to translate costs no model call). Each
  /// description is re-cleaned of raw/escaped HTML before it reaches the model
  /// (messy feeds like Simon Willison's ship escaped tags in `<description>`),
  /// so the model gets plain text and translates reliably. Any per-slot miss
  /// keeps that article's original text (never blank, never dropped).
  Future<OnDeviceBriefing> translateSource(
    OnDeviceBriefing briefing,
    String sourceName,
    String languageCode, {
    void Function(EngineFailureDetail detail)? onEngineFailure,
  }) async {
    final articles = briefing.articles
        .where((a) => a.sourceName == sourceName)
        .toList();
    if (articles.isEmpty) return briefing;

    // Cheap same-language detection, decided PER ARTICLE.
    //
    // It used to be decided once per source, from a sample of all of them: one
    // Spanish item in a mostly-English feed (or a Spanish site quoting an
    // English headline) then skipped the WHOLE source, and those items stayed
    // in their original language for good. A feed is not a language.
    //
    // Pack each article to translate as `title ||| cleanBrief` (brief omitted
    // when empty), cleaning the brief of any raw/escaped HTML first.
    final pending = <int>[];
    final inputs = <String>[];
    final cleaned = List<String>.filled(articles.length, '');
    for (var i = 0; i < articles.length; i++) {
      final a = articles[i];
      final brief = extractor.cleanBrief(a.description);
      cleaned[i] = brief;
      if (looksTargetLanguage('${a.title} $brief', languageCode)) continue;
      pending.add(i);
      inputs.add(brief.isNotEmpty ? '${a.title} ||| $brief' : a.title);
    }
    if (pending.isEmpty) return briefing;

    final translated = await translator.translate(
      inputs,
      languageCode: languageCode,
      temperature: translateTemperature,
      topK: translateTopK,
      topP: translateTopP,
      onEngineFailure: onEngineFailure,
    );

    return _applyTranslations(
      briefing,
      [for (final i in pending) articles[i]],
      [for (final i in pending) cleaned[i]],
      translated,
    );
  }

  /// Writes one batch of model output back onto [briefing].
  ///
  /// [articles], [cleaned] and [translated] are parallel lists: the article the
  /// line belongs to, the brief that was sent with it, and the model's answer
  /// (`null` when that slot produced nothing usable — the article then keeps
  /// its original text, never blank and never dropped). Each article is looked
  /// up by key in the briefing HANDED IN, so a briefing that changed while the
  /// batch was running (a summary that landed meanwhile) is respected.
  OnDeviceBriefing _applyTranslations(
    OnDeviceBriefing briefing,
    List<BriefingArticle> articles,
    List<String> cleaned,
    List<String?> translated,
  ) {
    var updated = briefing;
    for (var slot = 0; slot < articles.length; slot++) {
      final line = slot < translated.length ? translated[slot] : null;
      if (line == null) continue; // keep native text for this slot
      final parts = line.split('|||');
      // Model output gets the same invisible-character scrub as feed text: a
      // small model can emit a zero-width space or a stray BOM, and the card
      // then renders with a blank gap nothing in the text explains.
      final t = extractor.stripInvisible(parts[0]);
      if (t.isEmpty) continue; // never blank a title
      final d = parts.length > 1
          ? extractor.cleanBrief(parts.sublist(1).join('|||'))
          : '';
      final current = updated.articleForKey(articles[slot].key);
      if (current == null) continue;
      updated = updated.replaceArticle(
        current.key,
        current.copyWith(
          translatedTitle: t,
          // Only carry a translated brief when the item actually had one.
          translatedDescription: cleaned[slot].isNotEmpty && d.isNotEmpty
              ? d
              : null,
        ),
      );
    }
    return updated;
  }

  /// Translates the briefing the reader ALREADY HAS OPEN, in reading order, one
  /// small batch at a time, publishing each batch as it lands.
  ///
  /// WHY THIS EXISTS (decisión del 2026-09-06). Translating in the background
  /// was a bet that the reader would open the briefing, paid in battery and in
  /// the same eight-minute budget the per-theme digests need — and when the
  /// budget ran out the translation was the stage that silently lost, which is
  /// how the Pixel got a briefing whose digests were Spanish and whose
  /// headlines were English, announced as "listo". Here nothing is speculative:
  /// the reader is looking at the briefing, so every batch is work he is about
  /// to read.
  ///
  /// Contract:
  ///   * READING ORDER — [OnDeviceBriefing.articles] is the order the screen
  ///     renders, so what is nearest the top is translated first. That is the
  ///     whole prioritization: no viewport tracking, no scroll listeners.
  ///   * NEVER BLOCKS — the briefing is already on screen; each batch of at
  ///     most [OnDeviceTranslator.maxItemsPerBatch] items is published through
  ///     [onBatch] the moment it lands, and [onBatch] returns the briefing the
  ///     next batch continues from (so a summary that arrived meanwhile is not
  ///     overwritten).
  ///   * INTERRUPTIBLE — [shouldContinue] is consulted before every batch and
  ///     again before publishing it. The reader who leaves the screen stops
  ///     paying for the model within one batch; the batch already in flight
  ///     cannot be un-run (there is no cancel at the native session), so it is
  ///     simply not published.
  ///   * SKIPS WHAT IS DONE — an article that already carries a translation, or
  ///     that already looks like the target language, costs no model call. That
  ///     is what makes opening the briefing twice cheap.
  ///   * NEVER THROWS — a failed batch leaves its articles in their original
  ///     language and the next batch is still attempted; [onEngineFailure]
  ///     fires at most once with the real cause, so untranslated text always
  ///     has an explanation on screen instead of looking like a lazy
  ///     translator.
  ///
  /// [runBatch] wraps each batch so the caller can put it on the shared model
  /// queue. Per BATCH, deliberately, not per briefing: a summary the reader
  /// taps waits at most four items, never a whole translation.
  Future<OnDeviceBriefing> translateInReadingOrder(
    OnDeviceBriefing briefing, {
    required String languageCode,
    required Future<OnDeviceBriefing> Function(OnDeviceBriefing updated) onBatch,
    bool Function()? shouldContinue,
    void Function(EngineFailureDetail detail)? onEngineFailure,
    BriefingTranslationBatchRunner? runBatch,
  }) async {
    var current = briefing;
    var reported = false;
    void report(EngineFailureDetail detail) {
      if (reported) return;
      reported = true;
      onEngineFailure?.call(detail);
    }

    bool keepGoing() => shouldContinue == null || shouldContinue();

    final keys = <String>[
      for (final a in briefing.articles)
        if (needsTranslation(a, languageCode, extractor)) a.key,
    ];

    for (var start = 0; start < keys.length; start += readingBatchSize) {
      if (!keepGoing()) break;
      final end = (start + readingBatchSize).clamp(0, keys.length);
      final articles = <BriefingArticle>[];
      for (final key in keys.sublist(start, end)) {
        final a = current.articleForKey(key);
        // Re-checked against the CURRENT briefing: something may have
        // translated it in the meantime, and paying twice for the same
        // headline is exactly what this whole design is avoiding.
        if (a != null && needsTranslation(a, languageCode, extractor)) {
          articles.add(a);
        }
      }
      if (articles.isEmpty) continue;

      final cleaned = [
        for (final a in articles) extractor.cleanBrief(a.description),
      ];
      final inputs = [
        for (var i = 0; i < articles.length; i++)
          cleaned[i].isNotEmpty
              ? '${articles[i].title} ||| ${cleaned[i]}'
              : articles[i].title,
      ];

      List<String?> translated;
      Future<List<String?>> job() => translator.translate(
            inputs,
            languageCode: languageCode,
            temperature: translateTemperature,
            topK: translateTopK,
            topP: translateTopP,
            onEngineFailure: report,
          );
      try {
        translated = runBatch == null ? await job() : await runBatch(job);
      } catch (_) {
        // The batch could not even run (a queue that refused it). Its articles
        // keep their original text; the rest of the briefing still gets its
        // turn.
        continue;
      }

      // Asked AGAIN after the model came back: the reader may have left while
      // this batch was decoding, and publishing then would repaint a screen
      // nobody is looking at — and persist behind his back.
      if (!keepGoing()) break;

      final updated = _applyTranslations(current, articles, cleaned, translated);
      if (identical(updated, current)) continue; // nothing landed; nothing to say
      current = await onBatch(updated);
    }
    return current;
  }

  /// Whether [article] still needs a model call to be readable in
  /// [languageCode]: nothing translated yet, and it does not already look like
  /// the target language.
  static bool needsTranslation(
    BriefingArticle article,
    String languageCode,
    SourceContentExtractor extractor,
  ) {
    if ((article.translatedTitle ?? '').trim().isNotEmpty) return false;
    final brief = extractor.cleanBrief(article.description);
    return !looksTargetLanguage('${article.title} $brief', languageCode);
  }

  /// Cheap language guess for the PER-ARTICLE same-language skip. Returns true
  /// when [text] already looks like [code]'s language, so no translation is
  /// needed. Biased to translate when there is no positive evidence of the
  /// target language (short English HN headlines have no Spanish signal →
  /// translate to es).
  static bool looksTargetLanguage(String text, String code) {
    final lower = text.toLowerCase();
    if (lower.trim().isEmpty) return true; // nothing to translate
    final hasEsChars = RegExp(r'[áéíóúñ¿¡]').hasMatch(lower);
    final words = lower
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length > 1)
        .toList();
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
    'de',
    'la',
    'el',
    'que',
    'en',
    'los',
    'del',
    'las',
    'por',
    'una',
    'para',
    'con',
    'su',
    'al',
    'un',
    'como',
    'más',
    'pero',
    'sus',
    'le',
    'ya',
    'este',
    'sí',
    'porque',
    'esta',
    'son',
  };
  static const Set<String> _enStop = {
    'the',
    'of',
    'and',
    'to',
    'in',
    'for',
    'is',
    'on',
    'with',
    'that',
    'it',
    'as',
    'are',
    'at',
    'by',
    'an',
    'be',
    'this',
    'from',
    'or',
    'was',
    'how',
    'why',
    'new',
    'your',
  };
}
