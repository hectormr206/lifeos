import '../../local_model/domain/engine_failure_detail.dart';
import '../../local_model/domain/on_device_translator.dart';
import '../data/source_content_extractor.dart';
import 'morning_briefing.dart';

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

    var updated = briefing;
    for (var slot = 0; slot < pending.length; slot++) {
      final i = pending[slot];
      final line = translated[slot];
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
      final current = updated.articleForKey(articles[i].key);
      if (current == null) continue;
      updated = updated.replaceArticle(
        current.key,
        current.copyWith(
          translatedTitle: t,
          // Only carry a translated brief when the item actually had one.
          translatedDescription: cleaned[i].isNotEmpty && d.isNotEmpty
              ? d
              : null,
        ),
      );
    }
    return updated;
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
