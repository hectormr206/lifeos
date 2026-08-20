import 'dart:convert';

import '../../morning_briefing/domain/source_fetcher.dart';
import '../domain/web_search_backend.dart';

/// The SearXNG web-search backend: queries the USER'S OWN SearXNG instance and
/// maps its results onto the shared [DdgResult] link model.
///
/// PRIVATE by design — the query goes to a metasearch engine the user controls
/// (their VPS / home server), not a public third party. The primary path is
/// SearXNG's JSON API (`GET <base>/search?q=<query>&format=json`), which is the
/// cleanest to parse. If the instance has JSON output DISABLED (SearXNG ships it
/// off by default, so `format=json` may 403 or return HTML), we FALL BACK to a
/// best-effort scrape of the HTML results page. JSON is always tried first.
///
/// Reuses the same fresh, unpaired [SourceFetcher] as every other web hop, so
/// the request never inherits the paired engine base URL, auth, or TLS pinning.
/// Fails SOFT like the DDG backend: an unreachable/invalid instance surfaces as
/// a throw (fetcher) or an empty list, letting the pipeline collapse cleanly.
class SearxngBackend implements WebSearchBackend {
  SearxngBackend({
    required SourceFetcher fetcher,
    required String baseUrl,
    this.maxResults = 5,
    String accessKey = '',
  })  : _fetcher = fetcher, // ignore: prefer_initializing_formals
        _baseUrl = baseUrl, // ignore: prefer_initializing_formals
        _accessKey = accessKey;

  final SourceFetcher _fetcher;
  final String _baseUrl;

  /// Where this backend points. Visible so a test can assert which instance
  /// was chosen without reaching into the fetcher.
  String get baseUrl => _baseUrl;

  /// The key this backend will send, if any. Visible for the same reason: the
  /// property that matters is that a stranger's instance NEVER receives ours.
  String get accessKey => _accessKey;

  /// The key for a PRIVATE instance. Empty for a public one the user pointed
  /// at themselves, which must not receive a header it never asked for.
  ///
  /// Sent as a HEADER, never in the query string: there it would land in the
  /// server's access log, in the history of anyone who pastes the URL, and in
  /// every proxy in between.
  final String _accessKey;

  Map<String, String>? get _headers =>
      _accessKey.isEmpty ? null : {'X-LifeOS-Search-Key': _accessKey};

  /// Hard cap on the number of links returned (top hits only).
  final int maxResults;

  /// Builds the SearXNG JSON search URL for [query] against [baseUrl] (visible
  /// for testing the exact request the fetcher receives). Trailing slashes on
  /// the base are normalised away so `https://s.example` and
  /// `https://s.example/` both produce a well-formed `/search` path.
  static String jsonQueryUrl(String baseUrl, String query) {
    final base = _normalizeBase(baseUrl);
    return '$base/search?q=${Uri.encodeQueryComponent(query)}&format=json';
  }

  /// Builds the SearXNG HTML search URL (fallback path when JSON is disabled).
  static String htmlQueryUrl(String baseUrl, String query) {
    final base = _normalizeBase(baseUrl);
    return '$base/search?q=${Uri.encodeQueryComponent(query)}';
  }

  static String _normalizeBase(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  @override
  Future<List<DdgResult>> search(String query) async {
    if (_normalizeBase(_baseUrl).isEmpty) return const [];
    // Primary path: the JSON API.
    try {
      final body =
          await _fetcher.fetch(jsonQueryUrl(_baseUrl, query), headers: _headers);
      final parsed = parseJson(body);
      if (parsed.isNotEmpty) return parsed;
      // A 200 that wasn't JSON (some instances serve the HTML page for
      // `format=json` when it is disabled) → try the HTML fallback below.
    } catch (_) {
      // JSON endpoint unreachable or non-2xx → fall through to HTML.
    }
    // Fallback path: scrape the HTML results page.
    try {
      final html =
          await _fetcher.fetch(htmlQueryUrl(_baseUrl, query), headers: _headers);
      return parseHtml(html);
    } catch (_) {
      return const [];
    }
  }

  /// Parses a SearXNG `format=json` response body into [DdgResult]s. Returns an
  /// empty list for anything that isn't a JSON object with a `results` array
  /// (e.g. the HTML page served when JSON is disabled), so the caller can fall
  /// back cleanly. Each entry needs at least a non-empty `url`.
  List<DdgResult> parseJson(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    final rawResults = decoded['results'];
    if (rawResults is! List) return const [];
    final results = <DdgResult>[];
    final seen = <String>{};
    for (final entry in rawResults) {
      if (results.length >= maxResults) break;
      if (entry is! Map) continue;
      final url = (entry['url'] as Object?)?.toString().trim() ?? '';
      if (url.isEmpty || !_isAbsolute(url) || !seen.add(url)) continue;
      final title = (entry['title'] as Object?)?.toString().trim() ?? '';
      results.add(DdgResult(title: title.isEmpty ? _hostOf(url) : title, url: url));
    }
    return results;
  }

  // Best-effort HTML result reader for a SearXNG results page: each hit's title
  // link renders as `<h3><a href="URL" …>Title</a></h3>`.
  static final RegExp _htmlAnchor = RegExp(
    r'<h3[^>]*>\s*<a\s[^>]*?href="([^"]+)"[^>]*>(.*?)</a>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _anyTag = RegExp(r'<[^>]+>');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Best-effort parse of a SearXNG HTML results page (fallback path). Pulls the
  /// `<h3><a href>` title links; skips anything not absolute.
  List<DdgResult> parseHtml(String html) {
    final results = <DdgResult>[];
    final seen = <String>{};
    for (final match in _htmlAnchor.allMatches(html)) {
      if (results.length >= maxResults) break;
      final url = (match.group(1) ?? '').trim();
      if (url.isEmpty || !_isAbsolute(url) || !seen.add(url)) continue;
      final title = _clean(match.group(2) ?? '');
      results.add(DdgResult(title: title.isEmpty ? _hostOf(url) : title, url: url));
    }
    return results;
  }

  bool _isAbsolute(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasScheme && uri.host.isNotEmpty;
  }

  String _clean(String raw) {
    final stripped = raw.replaceAll(_anyTag, ' ');
    return stripped
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(_whitespace, ' ')
        .trim();
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
