import '../../morning_briefing/data/source_content_extractor.dart';
import '../../morning_briefing/domain/source_fetcher.dart';
import '../domain/web_search_backend.dart';

/// One cited source in a web-search answer: its title and canonical URL. Fed to
/// the model as part of the context block AND surfaced to the user as a
/// numbered "Fuentes:"/"Sources:" list under the reply.
class WebSource {
  const WebSource({required this.title, required this.url});

  final String title;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is WebSource && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);

  @override
  String toString() => 'WebSource($title, $url)';
}

/// Outcome of a web-search run: a compact [contextBlock] to prepend to the
/// user's message (so the on-device model can ground its answer) and the list
/// of [sources] to show under the reply.
///
/// [ok] is `false` when the search could not be completed (DDG unreachable,
/// zero results, or nothing readable). In that case [contextBlock] carries a
/// neutral-Spanish "I couldn't search" note the model can honour, and [sources]
/// is empty — the pipeline NEVER throws.
class WebSearchResult {
  const WebSearchResult({required this.contextBlock, required this.sources, required this.ok});

  final String contextBlock;
  final List<WebSource> sources;
  final bool ok;

  bool get hasSources => sources.isNotEmpty;
}

/// The on-device web-search pipeline (roadmap slice B4).
///
/// query → [WebSearchBackend] (DuckDuckGo or the user's SearXNG) → top result
/// URLs → fetch the top few pages → extract readable text (the existing,
/// length-capped [SourceContentExtractor]) → assemble a compact context block +
/// a sources list. Every network hop reuses the SAME morning-briefing
/// [SourceFetcher] (fresh unpaired `dio`, bounded timeouts, plain UA,
/// fail-soft). The backend is chosen by the user in Settings; the rest of the
/// pipeline is backend-agnostic.
class WebSearchPipeline {
  WebSearchPipeline({
    required WebSearchBackend search,
    required SourceFetcher fetcher,
    SourceContentExtractor? extractor,
    int maxPages = 3,
  }) : this._(search, fetcher, extractor, maxPages);

  WebSearchPipeline._(this._search, this._fetcher, SourceContentExtractor? extractor, this.maxPages)
      : _extractor = extractor ?? const SourceContentExtractor();

  /// Neutral-Spanish signal prepended when the search could not run — the model
  /// is told to answer from what it already knows rather than inventing links.
  static const String noSearchNote =
      'No pude buscar en internet en este momento; responde con lo que ya sepas '
      'y aclara que no consultaste fuentes web.';

  /// How many of the top DDG results to actually fetch + read (2–3 keeps the
  /// prompt small for the on-device model).
  final int maxPages;

  final WebSearchBackend _search;
  final SourceFetcher _fetcher;
  final SourceContentExtractor _extractor;

  /// Runs the full pipeline for [query]. Never throws — any failure collapses
  /// to a fail-soft [WebSearchResult] with `ok == false`.
  Future<WebSearchResult> run(String query) async {
    List<DdgResult> hits;
    try {
      hits = await _search.search(query);
    } catch (_) {
      return const WebSearchResult(contextBlock: noSearchNote, sources: [], ok: false);
    }
    if (hits.isEmpty) {
      return const WebSearchResult(contextBlock: noSearchNote, sources: [], ok: false);
    }

    final buffer = StringBuffer('Resultados web para "$query":\n');
    final sources = <WebSource>[];
    var index = 0;
    for (final hit in hits.take(maxPages)) {
      String body;
      try {
        body = await _fetcher.fetch(hit.url);
      } catch (_) {
        // Per-source fail-soft: skip a page that won't load rather than aborting
        // the whole search.
        continue;
      }
      final extract = _extractor.extract(body, url: hit.url);
      if (extract.isEmpty) continue;
      index++;
      final title = hit.title.isNotEmpty ? hit.title : extract.title;
      buffer.writeln('[$index] $title (${_hostOf(hit.url)})');
      buffer.writeln(extract.text);
      sources.add(WebSource(title: title, url: hit.url));
    }

    if (sources.isEmpty) {
      // DDG had links but none were readable → still fail soft.
      return const WebSearchResult(contextBlock: noSearchNote, sources: [], ok: false);
    }
    return WebSearchResult(contextBlock: buffer.toString().trim(), sources: sources, ok: true);
  }

  String _hostOf(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }
}
