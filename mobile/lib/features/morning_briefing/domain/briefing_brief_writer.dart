import '../../local_model/domain/local_llm_engine.dart';
import '../data/source_content_extractor.dart';
import 'morning_briefing.dart';
import 'source_fetcher.dart';

/// Writes a SHORT brief on-device for briefing items whose feed carried none —
/// the THIRD stage of the pipeline, after fetch+assemble and translation.
///
/// WHY THIS EXISTS. Some feeds ship a headline and nothing else: Hugging Face's
/// blog carries only guid/link/pubDate/title, and Hacker News has no body at
/// all. The phone READ the feed's summary, so when there was none the card had
/// nothing to show and fell back to a grey "sin resumen" hint.
///
/// The laptop's briefing never had that gap, and not because its feeds are
/// better — because it does not read a summary, it WRITES one (see
/// `axi/briefing.py`: `summary: <resumen corto 1-2 líneas en español>`). This
/// is the phone doing the same thing with the on-device model.
///
/// The feed's own words always win. This only ever fills a genuine blank, and
/// the result is stored in [BriefingArticle.generatedBrief] so a real
/// description is never overwritten by a generated one.
///
/// Contract: NEVER throws. A per-item failure leaves that item without a brief
/// (the existing hint) and the rest still get theirs.
class BriefingBriefWriter {
  const BriefingBriefWriter({
    required this.engine,
    required this.fetcher,
    required this.extractor,
  });

  final LocalLlmEngine engine;
  final SourceFetcher fetcher;
  final SourceContentExtractor extractor;

  /// Low temperature: this is reporting, not writing. The model should
  /// compress what the page says, and invent nothing — a briefing that
  /// hallucinates is worse than one with a blank.
  static const double temperature = 0.2;
  static const int topK = 20;
  static const double topP = 0.9;

  /// Upper bound on model calls per briefing run.
  ///
  /// Each brief costs a page fetch plus an on-device generation, and an
  /// unbounded loop over a bad day's feeds would run for a very long time on
  /// battery. Items beyond the cap are NOT silently dropped: they keep the
  /// existing "sin resumen" hint, which is visible on the card.
  static const int maxBriefsPerRun = 20;

  /// A brief must be short enough to read at a glance; anything longer is the
  /// model ignoring the instruction, and is cut rather than trusted.
  static const int maxBriefChars = 240;

  /// Fills in the missing briefs of [briefing], returning an updated briefing.
  /// [onItem] fires before each model call (UI-progress seam).
  Future<OnDeviceBriefing> fillMissing(
    OnDeviceBriefing briefing, {
    void Function(int index, int total)? onItem,
  }) async {
    try {
      final pending = briefing.articles
          .where((a) => a.displayDescription.trim().isEmpty && a.url.trim().isNotEmpty)
          .take(maxBriefsPerRun)
          .toList(growable: false);
      if (pending.isEmpty) return briefing;

      try {
        await engine.load();
      } catch (_) {
        // No model on this device: every card keeps its hint. Not an error —
        // the briefing itself is already complete and readable.
        return briefing;
      }

      var updated = briefing;
      for (var i = 0; i < pending.length; i++) {
        onItem?.call(i, pending.length);
        final brief = await _briefFor(pending[i]);
        if (brief == null) continue; // keep the hint for this one
        final current = updated.articleForKey(pending[i].key);
        if (current == null) continue;
        updated = updated.replaceArticle(current.key, current.copyWith(generatedBrief: brief));
      }
      return updated;
    } catch (_) {
      // Any unexpected failure: the briefing is returned as it came in.
      return briefing;
    }
  }

  /// One item's brief, or null when the page could not be read or the model
  /// gave nothing usable. Null is a real answer — the card shows its hint.
  Future<String?> _briefFor(BriefingArticle article) async {
    try {
      final body = await fetcher.fetch(article.url);
      final extract = extractor.extract(body, url: article.url);
      if (extract.isEmpty) return null;

      final result = await engine.generate(
        _prompt(title: article.displayTitle, content: extract.text),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      final brief = extractor.stripInvisible(result.text);
      if (brief.isEmpty) return null;
      return brief.length <= maxBriefChars
          ? brief
          : '${brief.substring(0, maxBriefChars).trimRight()}…';
    } catch (_) {
      return null;
    }
  }

  /// Mirrors the laptop's instruction (`axi/briefing.py`): one or two lines, in
  /// Spanish, saying what the article is about — no preamble, no headline
  /// echo, nothing the model was not told.
  static String _prompt({required String title, required String content}) =>
      'Resume en español, en 1 o 2 líneas, de qué trata este artículo.\n'
      'Responde SOLO con el resumen: sin introducción, sin repetir el título, '
      'sin comillas y sin viñetas. No inventes datos que no estén en el texto.\n\n'
      'Título: $title\n\n'
      'Artículo:\n$content';
}
