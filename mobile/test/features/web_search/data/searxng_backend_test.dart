// Proves the SearXNG backend: it queries the user's instance JSON API
// (`/search?q=…&format=json`), maps `results[]` onto the shared DdgResult
// model, falls back to scraping the HTML results page when JSON is disabled,
// and fails soft (empty list) when the instance is unreachable. No network —
// everything runs against a scripted fetcher.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/searxng_backend.dart';

/// Serves canned bodies keyed by URL; throws (like DioSourceFetcher) for any
/// URL not scripted.
class _ScriptedFetcher implements SourceFetcher {
  _ScriptedFetcher(this.bodies);
  final Map<String, String> bodies;
  final List<String> fetched = [];

  @override
  Future<String> fetch(String url) async {
    fetched.add(url);
    final body = bodies[url];
    if (body == null) throw Exception('no body for $url');
    return body;
  }
}

class _FailingFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url) async => throw Exception('unreachable');
}

const _base = 'https://searx.example';

const _json = '''
{
  "query": "mars rover",
  "results": [
    {"url": "https://news.example/a", "title": "Alpha article", "content": "snippet a"},
    {"url": "https://news.example/b", "title": "Beta article", "content": "snippet b"},
    {"url": "https://news.example/a", "title": "Duplicate", "content": "dup"}
  ]
}
''';

const _html = '''
<div id="results">
  <article class="result">
    <h3><a href="https://news.example/x" class="url_header">X page</a></h3>
    <p class="content">snippet x</p>
  </article>
  <article class="result">
    <h3><a href="https://news.example/y">Y &amp; more</a></h3>
  </article>
</div>
''';

void main() {
  SearxngBackend backend(SourceFetcher fetcher, {String base = _base}) =>
      SearxngBackend(fetcher: fetcher, baseUrl: base);

  test('parses the JSON results[] into DdgResults (title + url), de-duping urls', () async {
    final fetcher = _ScriptedFetcher({
      SearxngBackend.jsonQueryUrl(_base, 'mars rover'): _json,
    });

    final results = await backend(fetcher).search('mars rover');

    expect(results, hasLength(2));
    expect(results[0].title, 'Alpha article');
    expect(results[0].url, 'https://news.example/a');
    expect(results[1].title, 'Beta article');
    expect(results[1].url, 'https://news.example/b');
    // The JSON endpoint was hit (primary path), not the HTML page.
    expect(fetcher.fetched.single, SearxngBackend.jsonQueryUrl(_base, 'mars rover'));
  });

  test('parseJson returns empty for a non-JSON body (JSON disabled)', () {
    final b = backend(_FailingFetcher());
    expect(b.parseJson('<html><body>not json</body></html>'), isEmpty);
    expect(b.parseJson('{"results": "not a list"}'), isEmpty);
    expect(b.parseJson('{}'), isEmpty);
  });

  test('falls back to scraping the HTML page when JSON yields nothing', () async {
    // JSON URL returns the HTML page (format=json disabled → same HTML), so the
    // JSON parse is empty and the backend re-fetches the HTML query URL.
    final fetcher = _ScriptedFetcher({
      SearxngBackend.jsonQueryUrl(_base, 'q'): '<html>not json</html>',
      SearxngBackend.htmlQueryUrl(_base, 'q'): _html,
    });

    final results = await backend(fetcher).search('q');

    expect(results, hasLength(2));
    expect(results[0].url, 'https://news.example/x');
    expect(results[0].title, 'X page');
    expect(results[1].url, 'https://news.example/y');
    expect(results[1].title, 'Y & more');
  });

  test('fails soft (empty) when the instance is unreachable', () async {
    final results = await backend(_FailingFetcher()).search('anything');
    expect(results, isEmpty);
  });

  test('returns empty (no request) when the base URL is blank', () async {
    final fetcher = _ScriptedFetcher(const {});
    final results = await backend(fetcher, base: '   ').search('q');
    expect(results, isEmpty);
    expect(fetcher.fetched, isEmpty);
  });

  test('normalises a trailing slash on the base URL', () {
    expect(
      SearxngBackend.jsonQueryUrl('https://searx.example/', 'a b'),
      'https://searx.example/search?q=a+b&format=json',
    );
  });
}
