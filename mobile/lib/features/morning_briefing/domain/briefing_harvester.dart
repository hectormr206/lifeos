import '../data/source_content_extractor.dart';
import 'briefing_assembler.dart';
import 'source_fetcher.dart';

/// Hacker News front-page candidates via the Algolia JSON API. Fetched with the
/// same browser-like [SourceFetcher] as the feeds; parsed by
/// [SourceContentExtractor.parseHackerNews]. Each item keeps its `objectID`, so
/// the on-demand "Ver resumen de comentarios" action can fetch the thread.
const String hnFrontPageUrl =
    'https://hn.algolia.com/api/v1/search?tags=front_page';

/// The HN Algolia single-item (comments thread) endpoint prefix.
const String hnItemUrlPrefix = 'https://hn.algolia.com/api/v1/items/';

/// Reusable fetch+parse stage of the briefing pipeline: harvests every
/// configured feed plus Hacker News into [SourceHarvest]es, with per-source
/// failure isolation (a broken source becomes `failed: true`, never a throw).
///
/// Extracted from the notifier so the SAME harvest runs both in the foreground
/// (`MorningBriefingNotifier.generate`, with progress-label callbacks) and in
/// the headless WorkManager background task (no UI, no Riverpod).
class BriefingHarvester {
  const BriefingHarvester({required this.fetcher, required this.extractor});

  final SourceFetcher fetcher;
  final SourceContentExtractor extractor;

  /// Harvests [sources] in order, then Hacker News last (its own adapter, so
  /// the comments feature always exists). [onFeed] fires before each feed
  /// fetch with its 0-based index; [onHackerNews] fires before the HN fetch —
  /// both are UI-progress seams, unused by the background path.
  Future<List<SourceHarvest>> harvestAll(
    List<String> sources, {
    void Function(int index, int total)? onFeed,
    void Function()? onHackerNews,
  }) async {
    final harvests = <SourceHarvest>[];
    for (var i = 0; i < sources.length; i++) {
      onFeed?.call(i, sources.length);
      harvests.add(await harvestFeed(sources[i]));
    }
    onHackerNews?.call();
    harvests.add(await harvestHackerNews());
    return harvests;
  }

  /// Fetch + parse ONE feed URL. Never throws: any failure yields a
  /// `failed: true` harvest labeled with the URL's host.
  Future<SourceHarvest> harvestFeed(String url) async {
    try {
      final body = await fetcher.fetch(url);
      final feed = extractor.parseFeed(body, url: url);
      final name = feed.sourceTitle.trim().isEmpty
          ? hostLabel(url)
          : feed.sourceTitle.trim();
      return SourceHarvest(name: name, items: feed.items);
    } catch (_) {
      return SourceHarvest(name: hostLabel(url), failed: true);
    }
  }

  /// Fetch + parse the Hacker News front page. Never throws.
  Future<SourceHarvest> harvestHackerNews() async {
    try {
      final body = await fetcher.fetch(hnFrontPageUrl);
      final feed = extractor.parseHackerNews(body);
      return SourceHarvest(name: feed.sourceTitle, items: feed.items);
    } catch (_) {
      return const SourceHarvest(name: 'Hacker News', failed: true);
    }
  }

  /// Human-readable label for a source URL (its host, else the raw URL).
  static String hostLabel(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }
}
