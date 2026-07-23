/// A single search hit: the human title of the link and the REAL target URL.
///
/// Named for its DuckDuckGo-lite origin (where the URL is un-wrapped from DDG's
/// `duckduckgo.com/l/?uddg=` redirect), but it is now the SHARED link model for
/// EVERY [WebSearchBackend] — a SearXNG result maps onto the same shape. Kept in
/// `domain` so both the interface and its implementations depend on it without a
/// cycle.
class DdgResult {
  const DdgResult({required this.title, required this.url});

  final String title;
  final String url;

  @override
  String toString() => 'DdgResult($title, $url)';
}

/// The pluggable search backend behind the web-search pipeline.
///
/// One method — turn a plain-text [query] into the top real result links — so
/// the pipeline (fetch top pages → extract text → context block + sources) is
/// identical regardless of WHERE the links came from. Two implementations ship:
/// [DuckDuckGoBackend] (the public DDG-lite scrape) and `SearxngBackend` (the
/// user's OWN SearXNG instance's JSON API).
///
/// Implementations MUST fail SOFT: on an unreachable/invalid backend they throw
/// (letting the pipeline collapse to its "couldn't search" note) or return an
/// empty list — they never surface a raw error to the caller.
abstract class WebSearchBackend {
  /// Runs [query] and returns the top real result links (may be empty).
  Future<List<DdgResult>> search(String query);
}
