import '../data/source_content_extractor.dart';
import 'briefing_source.dart';
import 'morning_briefing.dart';

/// One source's harvest after fetch + parse: its display [name], the parsed
/// [items] it yielded (possibly empty), and whether the fetch/parse [failed].
/// A failed OR empty-after-freshness source is recorded as skipped.
class SourceHarvest {
  const SourceHarvest({
    required this.name,
    this.section = kDefaultBriefingSection,
    this.items = const [],
    this.failed = false,
  });

  final String name;

  /// The theme this source was filed under. Carried from [BriefingSource] so
  /// the assembler can group and cap by SECTION instead of by feed.
  final String section;
  final List<ParsedFeedItem> items;
  final bool failed;
}

/// Pure briefing assembly — the fast, model-free core of the redesign.
///
/// Mirrors the laptop's freshness rule (`briefing._is_fresh`): keep only items
/// published TODAY or YESTERDAY in the device timezone. Then it builds the
/// briefing BY SECTION: each source contributes at most [perSourceCap] of its
/// newest items, the sources of a theme are interleaved, and the theme stops
/// at [sectionCap]. Sources with zero fresh items (or that failed to fetch)
/// are collected into [OnDeviceBriefing.skippedSources] for the "sin novedades
/// hoy" note. NO model summarization happens here.
class BriefingAssembler {
  const BriefingAssembler({
    this.perSourceCap = defaultPerSourceCap,
    this.sectionCap = defaultSectionCap,
  });

  /// Most articles ONE source may contribute to its section.
  ///
  /// Measured on the real feed list on 2026-08-24: La Jornada alone published
  /// 108 fresh items that day while Marca published 1. Capping per feed made
  /// the briefing a mirror of who publishes loudest; capping per feed WITHIN a
  /// theme keeps every source in the room without letting one own the shelf.
  ///
  /// Raised 6 -> 8 on 2026-08-29: the reader said he felt he was missing things.
  /// He was right. Measured that morning across all 16 feeds: 367 fresh items
  /// published, 52 reaching him.
  static const int defaultPerSourceCap = 8;

  /// Most articles one SECTION may show. They arrive collapsed behind their
  /// digest, so this is the depth available to whoever opens a theme, not what
  /// anyone must read.
  ///
  /// Subido 12 -> 20 el 2026-08-29 y devuelto a 12 el 2026-09-01, con la
  /// medición delante: en el Pixel, un boletín de ~100 noticias tarda NUEVE
  /// minutos (1 leyendo 23 fuentes, 4 traduciendo, 4 resumiendo ocho temas).
  /// La ventana que Android da a una tarea en segundo plano es de ~10 minutos y
  /// paramos a los 8, así que con 20 la generación automática de la mañana —la
  /// única que importa, porque es la que tiene que estar lista al tocar la
  /// notificación— no llegaba al final y los últimos temas quedaban sin
  /// resumen.
  ///
  /// Doce deja ~75 noticias, que sí caben, y de paso mejora la calidad del
  /// resumen: se escribe en tandas de cinco por orden de llegada, y con menos
  /// noticias por tema hay menos tandas que mezclan cosas sin relación (en
  /// México salía acero para obras públicas junto a un teléfono Samsung y a
  /// Olivia Rodrigo).
  ///
  /// Sigue siendo el cap que MUERDE: la cuota por fuente se queda por debajo a
  /// propósito, porque El País publicó 118 noticias ese día y La Jornada 98.
  static const int defaultSectionCap = 12;

  final int perSourceCap;
  final int sectionCap;

  /// True iff [published], in the device's local day, is [now]'s day or the day
  /// before. Undated items (`published == null`) are NOT fresh — without a
  /// timestamp recency cannot be proven (that was the laptop's v1 staleness bug).
  static bool isFresh(DateTime? published, {required DateTime now}) {
    if (published == null) return false;
    final local = published.toLocal();
    final pubDay = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    return pubDay == today || pubDay == yesterday;
  }

  OnDeviceBriefing assemble(
    List<SourceHarvest> harvests, {
    required DateTime now,
    required DateTime generatedAt,
  }) {
    final skipped = <String>[];
    // Section order = the order its first source appears in the config.
    final sectionOrder = <String>[];
    final freshBySection = <String, List<List<BriefingArticle>>>{};

    for (final harvest in mergeHarvestsByName(harvests)) {
      if (harvest.failed) {
        skipped.add(harvest.name);
        continue;
      }
      final fresh =
          harvest.items.where((i) => isFresh(i.published, now: now)).toList()
            ..sort(
              (a, b) => (b.published ?? DateTime(0)).compareTo(
                a.published ?? DateTime(0),
              ),
            );
      if (fresh.isEmpty) {
        skipped.add(harvest.name);
        continue;
      }
      final seenLinks = <String>{};
      final queue = [
        for (final item in fresh
            .where((i) => seenLinks.add(i.link))
            .take(perSourceCap))
          BriefingArticle(
            sourceName: harvest.name,
            section: harvest.section,
            title: item.title,
            url: item.link,
            description: item.description,
            publishedAt: item.published,
            hnObjectId: item.hnObjectId,
          ),
      ];
      if (queue.isEmpty) continue;
      if (!freshBySection.containsKey(harvest.section)) {
        sectionOrder.add(harvest.section);
      }
      freshBySection.putIfAbsent(harvest.section, () => []).add(queue);
    }

    final articles = <BriefingArticle>[];
    for (final section in sectionOrder) {
      articles.addAll(_interleave(freshBySection[section]!, sectionCap));
    }

    return OnDeviceBriefing(
      articles: articles,
      skippedSources: skipped,
      generatedAt: generatedAt,
    );
  }

  /// Round-robin across a section's sources, one article each per pass, until
  /// [cap]. Taking six from the loudest feed and then six from the next would
  /// bury the second source below the fold; interleaving means the top of a
  /// theme is what several sources led with.
  static List<BriefingArticle> _interleave(
    List<List<BriefingArticle>> queues,
    int cap,
  ) {
    final out = <BriefingArticle>[];
    var depth = 0;
    while (out.length < cap) {
      var tookOne = false;
      for (final queue in queues) {
        if (depth >= queue.length) continue;
        out.add(queue[depth]);
        tookOne = true;
        if (out.length == cap) return out;
      }
      if (!tookOne) break;
      depth++;
    }
    return out;
  }
}

/// Cosechas con el mismo nombre son la misma fuente.
///
/// Dos entradas distintas pueden acabar en el mismo feed — el 2026-08-20 el
/// feed de ciencia de BBC respondía 301 al general — y entonces el boletín
/// mostraba la fuente dos veces con las mismas noticias. Fusionarlas aquí
/// arregla también los dispositivos que ya tienen la URL vieja guardada, que
/// es la mayoría: quitarla de los valores por defecto no les llega.
///
/// Una copia fallida junto a una que sí trajo noticias NO cuenta como fallo:
/// el usuario tiene sus noticias, y decirle "sin novedades" sería mentira.
List<SourceHarvest> mergeHarvestsByName(List<SourceHarvest> harvests) {
  final order = <String>[];
  final items = <String, List<ParsedFeedItem>>{};
  final failed = <String, bool>{};
  final section = <String, String>{};

  for (final harvest in harvests) {
    if (!items.containsKey(harvest.name)) {
      order.add(harvest.name);
      failed[harvest.name] = true;
      section[harvest.name] = harvest.section;
    }
    items.putIfAbsent(harvest.name, () => []).addAll(harvest.items);
    if (!harvest.failed) failed[harvest.name] = false;
  }

  return [
    for (final name in order)
      SourceHarvest(
        name: name,
        section: section[name]!,
        items: items[name]!,
        failed: failed[name]!,
      ),
  ];
}
