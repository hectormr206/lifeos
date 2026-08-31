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

  /// Tope de UNA tanda, no del resumen entero.
  ///
  /// Subido de 420 el 2026-08-31. El lector explicó para qué usa el resumen:
  /// "que abarque todas las noticias y una buena parte de cada una, sin
  /// excepción… para que sin abrir la pestaña pueda enterarme de qué pasa y por
  /// qué". En 420 caracteres eso no cabe ni de lejos.
  static const int maxDigestChars = 700;

  /// Noticias por tanda.
  ///
  /// EL TECHO NO ES UNA PREFERENCIA, ES DEL MOTOR: `LocalModelConfig` crea el
  /// chat con `maxOutputTokens: 512` y eso no se puede subir por llamada.
  /// Pedirle veinte noticias en una sola respuesta devuelve un párrafo cortado
  /// a media frase, que es PEOR que un resumen corto: parece completo y no lo
  /// está. Por eso el resumen de una sección se escribe por tandas y se une.
  static const int articlesPerPass = 5;

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
  /// El resumen de una sección, escrito por tandas y unido.
  ///
  /// Devuelve null sólo cuando NINGUNA tanda dio nada: cobertura parcial es
  /// mucho mejor que ninguna, y una tanda en la que el modelo se atraganta no
  /// puede llevarse por delante a las demás.
  Future<String?> _digest(BriefingSectionGroup group) async {
    final partes = <String>[];
    for (var i = 0; i < group.articles.length; i += articlesPerPass) {
      final tanda = group.articles.skip(i).take(articlesPerPass).toList();
      final texto = await _pass(group.section, tanda);
      if (texto != null) partes.add(texto);
    }
    if (partes.isEmpty) return null;
    return partes.join('\n\n');
  }

  Future<String?> _pass(String section, List<BriefingArticle> articles) async {
    try {
      final result = await engine.generate(
        promptFor(section: section, lines: _lines(articles)),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      final text = result.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      return clip(text);
    } catch (_) {
      return null;
    }
  }

  static String _lines(List<BriefingArticle> articles) {
    final lines = StringBuffer();
    for (final article in articles) {
      lines.writeln('- ${article.displayTitle} (${article.sourceName})');
      final brief = article.displayDescription.trim();
      if (brief.isNotEmpty) lines.writeln('  $brief');
    }
    return lines.toString();
  }

  /// Recorta a [maxDigestChars] SIN partir palabras.
  ///
  /// Cortar a media palabra ("hay discusiones so…") es peor que decir una frase
  /// menos: el lector no sabe si la idea seguía o si el modelo se colgó. Se
  /// busca el último cierre de frase que quepa; si no hay ninguno, se retrocede
  /// hasta el último espacio y ahí sí se marcan los puntos suspensivos, que
  /// entonces significan lo que parecen: "esto sigue".
  static String clip(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= maxDigestChars) return trimmed;
    final head = trimmed.substring(0, maxDigestChars);
    var cut = -1;
    for (final end in ['.', '?', '!', '…']) {
      final at = head.lastIndexOf(end);
      if (at > cut) cut = at;
    }
    // Una frase sola y larguísima no debe dejar un resumen de tres palabras:
    // por debajo de la mitad del cupo preferimos el corte por palabra.
    if (cut >= maxDigestChars ~/ 2) return head.substring(0, cut + 1).trimRight();
    final space = head.lastIndexOf(' ');
    final body = space > 0 ? head.substring(0, space) : head;
    return '${body.trimRight()}…';
  }

  /// The instruction. It names the job (help me decide what to open), forbids
  /// invention, and hands over exactly the headlines the reader already has.

  /// El texto que se le pide al modelo, expuesto para poder fijar en una prueba
  /// lo que se le exige — sin montar un grupo de noticias entero.
  static String promptFor({required String section, required String lines}) {
    return 'Estas son las noticias de hoy sobre $section.\n'
        'Cuenta en español QUÉ pasó en cada una y POR QUÉ importa, una o dos '
        'frases por noticia. No te dejes ninguna: quien lee esto quiere '
        'enterarse sin abrir las noticias.\n'
        'Si varias fuentes cuentan lo mismo, cuéntalo UNA vez. '
        'Usa solo lo que está aquí abajo: no inventes datos, nombres ni cifras. '
        'Empieza directamente por la noticia más importante. '
        'No empieces describiendo la lista: nada de "las noticias cubren", '
        '"se abordan diversos temas" ni "este resumen trata sobre". '
        'Responde SOLO con el resumen: sin título, sin viñetas y sin comillas.\n\n'
        '$lines';
  }
}
