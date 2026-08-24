import '../../local_model/domain/local_llm_engine.dart';
import 'morning_briefing.dart';

/// Writes ONE short paragraph per section — the thing the reader actually
/// reads at breakfast.
///
/// WHY THIS EXISTS. Measured over the real feed list on 2026-08-24: 249 fresh
/// articles in a single day. Even capped, that is dozens of cards, and reading
/// them one by one is not a briefing, it is a second inbox. The user said what
/// he needed in his own words: read one summary per theme, then decide whether
/// to open a story or move on to the next theme.
///
/// The digest is for DECIDING, never for replacing the news: every article
/// stays underneath, and the paragraph is built only from the headlines and
/// briefs already downloaded — the model is not asked to know anything it was
/// not shown.
///
/// Contract: NEVER throws, and NEVER invents. A section whose generation fails
/// simply has no paragraph, and the screen shows its headlines instead. A
/// plausible-sounding summary of news that was not read would be worse than no
/// summary at all.
class BriefingSectionDigestWriter {
  const BriefingSectionDigestWriter({required this.engine});

  final LocalLlmEngine engine;

  /// Low temperature: this is reporting, not writing.
  static const double temperature = 0.2;
  static const int topK = 20;
  static const double topP = 0.9;

  /// A digest has to be readable at a glance — a few sentences, not an essay.
  /// Anything longer is the model ignoring the instruction, and is cut rather
  /// than trusted.
  static const int maxDigestChars = 420;

  /// Headlines shown to the model per section. The whole point is that the
  /// section is already capped, so this is a safety rail, not a filter.
  static const int maxHeadlinesPerSection = 12;

  /// Fills [OnDeviceBriefing.sectionDigests], returning an updated briefing.
  /// [onSection] fires before each section is written (UI-progress seam).
  Future<OnDeviceBriefing> fillDigests(
    OnDeviceBriefing briefing, {
    void Function(int index, int total)? onSection,
  }) async {
    try {
      final sections = briefing.sections;
      if (sections.isEmpty) return briefing;

      try {
        await engine.load();
      } catch (_) {
        // No model, no paragraph. The headlines are still there.
        return briefing;
      }

      final digests = <String, String>{};
      for (var i = 0; i < sections.length; i++) {
        onSection?.call(i, sections.length);
        final text = await _digest(sections[i]);
        if (text != null) digests[sections[i].section] = text;
      }
      if (digests.isEmpty) return briefing;
      return briefing.withSectionDigests(digests);
    } catch (_) {
      return briefing;
    }
  }

  /// The model's paragraph for one section, or null when it gave nothing
  /// usable — in which case that section stays without one.
  Future<String?> _digest(BriefingSectionGroup group) async {
    try {
      final result = await engine.generate(
        _prompt(group),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      final text = result.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      return _clip(text);
    } catch (_) {
      return null;
    }
  }

  static String _clip(String text) => text.length <= maxDigestChars
      ? text
      : '${text.substring(0, maxDigestChars).trimRight()}…';

  /// The instruction. It names the job (help me decide what to open), forbids
  /// invention, and hands over exactly the headlines the reader already has.
  static String _prompt(BriefingSectionGroup group) {
    final lines = StringBuffer();
    for (final article in group.articles.take(maxHeadlinesPerSection)) {
      lines.writeln('- ${article.displayTitle} (${article.sourceName})');
      final brief = article.displayDescription.trim();
      if (brief.isNotEmpty) lines.writeln('  $brief');
    }
    return 'Estas son las noticias de hoy sobre ${group.section}.\n'
        'Escribe en español un resumen de 2 a 4 frases que le diga a alguien '
        'qué está pasando en este tema, para que decida qué leer.\n'
        'Si varias fuentes cuentan lo mismo, cuéntalo UNA vez. '
        'Usa solo lo que está aquí abajo: no inventes datos, nombres ni cifras. '
        'Responde SOLO con el resumen: sin título, sin viñetas y sin comillas.\n\n'
        '$lines';
  }
}
