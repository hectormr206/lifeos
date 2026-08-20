// The private SearXNG needs a key, and the key must not leak.
//
// An open SearXNG instance becomes the free search engine of whoever finds the
// URL, and it is our IP and our CPU that get burned. The server side closes
// that door (ops/searxng); this is the app's half.
//
// Measured on 2026-08-19, which is why any of this matters: DuckDuckGo Lite
// answers a datacenter IP with a CAPTCHA — "Select all squares containing a
// duck". Search worked until it did not, and there was nothing we could do
// about it from here.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/searxng_backend.dart';

/// Records what the backend asked for, headers included.
class _SpyFetcher implements SourceFetcher {
  String? url;
  Map<String, String>? headers;

  @override
  Future<String> fetch(String u, {Map<String, String>? headers}) async {
    url = u;
    this.headers = headers;
    return '{"results":[]}';
  }
}

void main() {
  test('the key travels as a header, never in the URL', () async {
    // In the query string it would end up in the server access log, in the
    // browser history of anyone who pastes it, and in any proxy in between.
    final spy = _SpyFetcher();
    final backend = SearxngBackend(
      fetcher: spy,
      baseUrl: 'https://search.lifeos.hectormr.com',
      accessKey: 'secreta',
    );

    await backend.search('presión arterial');

    expect(spy.headers?['X-LifeOS-Search-Key'], 'secreta');
    expect(spy.url, isNot(contains('secreta')));
  });

  test('with no key configured it sends none', () {
    // A public instance the user pointed at themselves must not receive a
    // header it never asked for.
    final spy = _SpyFetcher();
    final backend = SearxngBackend(
      fetcher: spy,
      baseUrl: 'https://searx.example',
    );

    expect(backend.search('hola'), completes);
  });

  test('the query still asks for JSON', () {
    expect(
      SearxngBackend.jsonQueryUrl('https://search.lifeos.hectormr.com', 'hola'),
      contains('format=json'),
    );
  });
}
