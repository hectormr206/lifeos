// Proves the web-search pipeline: DDG-lite → top URLs → fetch pages → extract
// text → compact context block + sources. Everything runs against a scripted
// fetcher (no network), reusing the real DDG parser + SourceContentExtractor.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/ddg_search_service.dart';
import 'package:lifeos/features/web_search/data/web_search_pipeline.dart';

/// Serves canned bodies keyed by URL, and records every fetched URL. Throws
/// (like the real DioSourceFetcher) for any URL not scripted.
class _ScriptedFetcher implements SourceFetcher {
  _ScriptedFetcher(this.bodies);

  final Map<String, String> bodies;
  final List<String> fetched = [];

  @override
  Future<String> fetch(String url, {Map<String, String>? headers}) async {
    fetched.add(url);
    final body = bodies[url];
    if (body == null) throw Exception('no body for $url');
    return body;
  }
}

/// Always throws, simulating DDG (or a page) being unreachable.
class _FailingFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url, {Map<String, String>? headers}) async => throw Exception('network down');
}

const _ddgHtml = '''
<table>
<tr><td><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fnews.example%2Fa&amp;rut=1" class='result-link'>Alpha article</a></td></tr>
<tr><td><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fnews.example%2Fb&amp;rut=2" class='result-link'>Beta article</a></td></tr>
</table>
''';

WebSearchPipeline _pipeline(SourceFetcher fetcher, {int maxPages = 3}) => WebSearchPipeline(
      search: DdgSearchService(fetcher: fetcher),
      fetcher: fetcher,
      maxPages: maxPages,
    );

void main() {
  test('assembles a context block and sources from the top results', () async {
    final fetcher = _ScriptedFetcher({
      DdgSearchService.queryUrl('mars rover'): _ddgHtml,
      'https://news.example/a': '<html><title>Alpha</title><body>Rover reached the crater today.</body></html>',
      'https://news.example/b': '<html><title>Beta</title><body>New photos were released.</body></html>',
    });

    final result = await _pipeline(fetcher).run('mars rover');

    expect(result.ok, isTrue);
    expect(result.contextBlock, contains('Resultados web para "mars rover":'));
    expect(result.contextBlock, contains('[1] Alpha article (news.example)'));
    expect(result.contextBlock, contains('Rover reached the crater today.'));
    expect(result.contextBlock, contains('[2] Beta article (news.example)'));

    expect(result.sources, hasLength(2));
    expect(result.sources[0].title, 'Alpha article');
    expect(result.sources[0].url, 'https://news.example/a');
    expect(result.sources[1].url, 'https://news.example/b');
  });

  test('respects maxPages — fetches only the top N result pages', () async {
    final fetcher = _ScriptedFetcher({
      DdgSearchService.queryUrl('q'): _ddgHtml,
      'https://news.example/a': '<html><body>only one read</body></html>',
      'https://news.example/b': '<html><body>should not be fetched</body></html>',
    });

    final result = await _pipeline(fetcher, maxPages: 1).run('q');

    expect(result.sources, hasLength(1));
    expect(fetcher.fetched, contains('https://news.example/a'));
    expect(fetcher.fetched, isNot(contains('https://news.example/b')));
  });

  test('fails soft (ok=false, neutral note, no sources) when DDG is unreachable', () async {
    final result = await _pipeline(_FailingFetcher()).run('anything');

    expect(result.ok, isFalse);
    expect(result.sources, isEmpty);
    expect(result.contextBlock, WebSearchPipeline.noSearchNote);
  });

  test('fails soft when DDG returns zero result links', () async {
    final fetcher = _ScriptedFetcher({
      DdgSearchService.queryUrl('empty'): '<html><body>no results here</body></html>',
    });

    final result = await _pipeline(fetcher).run('empty');

    expect(result.ok, isFalse);
    expect(result.sources, isEmpty);
  });

  test('skips result pages that fail to load but still returns readable ones', () async {
    // Page A is unreachable (not scripted → throws); page B reads fine.
    final fetcher = _ScriptedFetcher({
      DdgSearchService.queryUrl('mix'): _ddgHtml,
      'https://news.example/b': '<html><body>Beta content survives.</body></html>',
    });

    final result = await _pipeline(fetcher).run('mix');

    expect(result.ok, isTrue);
    expect(result.sources, hasLength(1));
    expect(result.sources.single.url, 'https://news.example/b');
  });
}
