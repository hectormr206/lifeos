import '../../morning_briefing/domain/source_fetcher.dart';
import '../domain/web_search_backend.dart';

// Re-export the shared link model so existing importers of this file (the
// pipeline, tests) keep resolving [DdgResult] without touching their imports —
// its home is now `domain/web_search_backend.dart`.
export '../domain/web_search_backend.dart' show DdgResult;

/// Pure, dependency-free reader for the DuckDuckGo-lite results HTML.
///
/// The app intentionally carries no `html` package, so the result anchors are
/// pulled out with a robust regex. DDG-lite renders each hit as
/// `<a … href="//duckduckgo.com/l/?uddg=<percent-encoded-url>&rut=…"
/// class='result-link'>Title</a>`: the real destination lives in the `uddg`
/// query parameter, percent-encoded, so we decode it back to the plain URL.
class DdgResultParser {
  const DdgResultParser({this.maxResults = 5});

  /// Hard cap on the number of links returned (top hits only).
  final int maxResults;

  // Any anchor whose href carries a `uddg=` param is a DDG result redirect.
  static final RegExp _anchor =
      RegExp(r'<a\s[^>]*?href="([^"]*uddg=[^"]*)"[^>]*>(.*?)</a>', dotAll: true, caseSensitive: false);
  // The percent-encoded destination sits after `uddg=`, up to the next `&`
  // (which begins `&amp;rut=` / `&rut=`) or the closing quote.
  static final RegExp _uddg = RegExp('uddg=([^&"]+)');
  static final RegExp _anyTag = RegExp(r'<[^>]+>');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Extracts up to [maxResults] real result links from a DDG-lite [html] page.
  /// Skips any anchor whose `uddg` value can't be decoded to an absolute URL.
  List<DdgResult> parse(String html) {
    final results = <DdgResult>[];
    final seen = <String>{};
    for (final match in _anchor.allMatches(html)) {
      if (results.length >= maxResults) break;
      final href = match.group(1) ?? '';
      final url = _decodeTarget(href);
      if (url == null || !seen.add(url)) continue;
      final title = _clean(match.group(2) ?? '');
      results.add(DdgResult(title: title.isEmpty ? _hostOf(url) : title, url: url));
    }
    return results;
  }

  String? _decodeTarget(String href) {
    final m = _uddg.firstMatch(href);
    if (m == null) return null;
    try {
      final decoded = Uri.decodeComponent(m.group(1)!);
      final uri = Uri.tryParse(decoded);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  String _clean(String raw) {
    final stripped = raw.replaceAll(_anyTag, ' ');
    return _decodeEntities(stripped).replaceAll(_whitespace, ' ').trim();
  }

  String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');

  String _hostOf(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }
}

/// The DuckDuckGo web-search backend: queries DuckDuckGo-lite for a plain-text
/// string and returns the top real result links.
///
/// LOCAL-FIRST & PUBLIC: the phone hits `lite.duckduckgo.com` DIRECTLY — no
/// self-hosted server, no account. Nothing of the user's data leaves; only
/// public results come in. Best-effort by nature (DDG-lite is an unofficial,
/// scrape-shaped surface).
///
/// Reuses the morning-briefing [SourceFetcher] (a FRESH, unpaired `dio` with
/// bounded timeouts + a plain UA), so the DDG request never inherits the paired
/// engine base URL, auth, or TLS pinning.
class DuckDuckGoBackend implements WebSearchBackend {
  DuckDuckGoBackend({required SourceFetcher fetcher, DdgResultParser? parser})
      : _fetcher = fetcher,
        _parser = parser ?? const DdgResultParser();

  static const String _endpoint = 'https://lite.duckduckgo.com/lite/';

  final SourceFetcher _fetcher;
  final DdgResultParser _parser;

  /// Builds the DDG-lite query URL for [query] (visible for testing the exact
  /// encoded request the fetcher receives).
  static String queryUrl(String query) => '$_endpoint?q=${Uri.encodeQueryComponent(query)}';

  /// Runs the search and returns the parsed top results. Throws (via the
  /// fetcher) on any transport/status failure so the pipeline can fail soft.
  @override
  Future<List<DdgResult>> search(String query) async {
    final html = await _fetcher.fetch(queryUrl(query));
    return _parser.parse(html);
  }
}

/// Backward-compatible alias for the pre-abstraction name. The DDG backend used
/// to be the ONLY search service; existing callers/tests that still say
/// `DdgSearchService(...)` / `DdgSearchService.queryUrl(...)` keep working.
typedef DdgSearchService = DuckDuckGoBackend;
