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

  /// Upper bound on MODEL calls per briefing run.
  ///
  /// An on-device generation is the expensive part (seconds of GPU work each),
  /// so a bad day's feeds must not turn into an unbounded inference loop on
  /// battery. Items beyond this budget are NOT left blank: they fall to the
  /// next rung of the ladder — the article's own opening words — which costs a
  /// page fetch and no inference at all.
  static const int maxBriefsPerRun = 20;

  /// Upper bound on ITEMS looked at per run (each costs one page fetch).
  /// Generous, because a fetch is cheap next to a generation, but still finite
  /// so a misconfigured feed list cannot fetch forever.
  static const int maxItemsPerRun = 60;

  /// A brief must be short enough to read at a glance; anything longer is the
  /// model ignoring the instruction, and is cut rather than trusted.
  static const int maxBriefChars = 240;

  /// Fills in the missing briefs of [briefing], returning an updated briefing.
  /// [onItem] fires before each item is worked on (UI-progress seam).
  ///
  /// THE LADDER (the user's "este resumen corto debe estar siempre"):
  ///   1. the feed's own brief wins and is never touched;
  ///   2. otherwise the page is fetched and the MODEL writes a short brief —
  ///      while the run's model budget lasts and the model is available;
  ///   3. otherwise the page's OWN opening words are used verbatim;
  ///   4. only when the page cannot be read at all does the card stay empty,
  ///      and it then says so. Nothing is invented from a page we never read —
  ///      a wrong summary is worse than an honest gap.
  Future<OnDeviceBriefing> fillMissing(
    OnDeviceBriefing briefing, {
    void Function(int index, int total)? onItem,
  }) async {
    try {
      final pending = briefing.articles
          .where((a) => a.displayDescription.trim().isEmpty && a.url.trim().isNotEmpty)
          .take(maxItemsPerRun)
          .toList(growable: false);
      if (pending.isEmpty) return briefing;

      // A missing/failing model no longer ends the stage: without it the ladder
      // simply starts one rung lower, at the article's own words.
      var modelReady = true;
      try {
        await engine.load();
      } catch (_) {
        modelReady = false;
      }

      var modelBudget = maxBriefsPerRun;
      var updated = briefing;
      for (var i = 0; i < pending.length; i++) {
        onItem?.call(i, pending.length);
        final text = await _readable(pending[i]);
        if (text == null) continue; // page unreadable → the honest gap
        final current = updated.articleForKey(pending[i].key);
        if (current == null) continue;

        String? written;
        if (modelReady && modelBudget > 0) {
          modelBudget--;
          written = await _modelBrief(pending[i], text);
        }
        updated = updated.replaceArticle(
          current.key,
          written != null
              ? current.copyWith(generatedBrief: written)
              : current.copyWith(sourceExcerpt: _excerpt(text)),
        );
      }
      return updated;
    } catch (_) {
      // Any unexpected failure: the briefing is returned as it came in.
      return briefing;
    }
  }

  /// The article page's readable text, or null when it could not be fetched or
  /// held nothing readable. Null is a real answer, and the only case in which a
  /// card is left without a short summary.
  Future<String?> _readable(BriefingArticle article) async {
    try {
      final body = await fetcher.fetch(article.url);
      final extract = extractor.extract(body, url: article.url);
      if (extract.isEmpty) return null;
      return extract.text;
    } catch (_) {
      return null;
    }
  }

  /// The model's short brief for [content], or null when the model gave nothing
  /// usable — in which case the caller drops to the excerpt rung.
  Future<String?> _modelBrief(BriefingArticle article, String content) async {
    try {
      final result = await engine.generate(
        _prompt(title: article.displayTitle, content: content),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      final brief = extractor.stripInvisible(result.text);
      if (brief.isEmpty) return null;
      return _clip(brief);
    } catch (_) {
      return null;
    }
  }

  /// The article's opening words, whitespace-collapsed and clipped. Verbatim
  /// source text — no model, so nothing can be hallucinated into it.
  static String _excerpt(String content) =>
      _clip(content.replaceAll(RegExp(r'\s+'), ' ').trim());

  static String _clip(String text) => text.length <= maxBriefChars
      ? text
      : '${text.substring(0, maxBriefChars).trimRight()}…';

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
