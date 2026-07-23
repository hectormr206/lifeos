import '../data/source_content_extractor.dart';
import 'morning_briefing.dart';

/// One source's harvest after fetch + parse: its display [name], the parsed
/// [items] it yielded (possibly empty), and whether the fetch/parse [failed].
/// A failed OR empty-after-freshness source is recorded as skipped.
class SourceHarvest {
  const SourceHarvest({required this.name, this.items = const [], this.failed = false});

  final String name;
  final List<ParsedFeedItem> items;
  final bool failed;
}

/// Pure briefing assembly — the fast, model-free core of the redesign.
///
/// Mirrors the laptop's freshness rule (`briefing._is_fresh`): keep only items
/// published TODAY or YESTERDAY in the device timezone. Then, per source:
/// sort newest-first and cap at [cap]. Sources with zero fresh items (or that
/// failed to fetch) are collected into [OnDeviceBriefing.skippedSources] for
/// the "sin novedades hoy" note. NO model summarization happens here.
class BriefingAssembler {
  const BriefingAssembler({this.cap = 10});

  /// Max fresh items kept per source.
  final int cap;

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
    final articles = <BriefingArticle>[];
    final skipped = <String>[];

    for (final harvest in harvests) {
      if (harvest.failed) {
        skipped.add(harvest.name);
        continue;
      }
      final fresh = harvest.items.where((i) => isFresh(i.published, now: now)).toList()
        ..sort((a, b) => (b.published ?? DateTime(0)).compareTo(a.published ?? DateTime(0)));
      if (fresh.isEmpty) {
        skipped.add(harvest.name);
        continue;
      }
      for (final item in fresh.take(cap)) {
        articles.add(BriefingArticle(
          sourceName: harvest.name,
          title: item.title,
          url: item.link,
          description: item.description,
          publishedAt: item.published,
          hnObjectId: item.hnObjectId,
        ));
      }
    }

    return OnDeviceBriefing(
      articles: articles,
      skippedSources: skipped,
      generatedAt: generatedAt,
    );
  }
}
