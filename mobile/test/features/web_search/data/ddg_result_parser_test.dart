// Proves DdgResultParser un-wraps DuckDuckGo-lite result anchors: the real
// destination lives percent-encoded in the `uddg` redirect param, and titles
// are stripped of tags + HTML entities. Pure, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/web_search/data/ddg_search_service.dart';

// A representative slice of a DDG-lite results page: each hit is an anchor
// wrapping `duckduckgo.com/l/?uddg=<encoded-url>&amp;rut=…`.
const _ddgHtml = '''
<html><body><table>
<tr><td>
  <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FCat&amp;rut=abc" class='result-link'>Cat - Wikipedia</a>
</td></tr>
<tr><td>
  <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fkittens&amp;rut=def" class='result-link'>Kittens &amp; <b>more</b></a>
</td></tr>
<tr><td>
  <a href="//duckduckgo.com/settings">Settings</a>
</td></tr>
</table></body></html>
''';

void main() {
  test('decodes the uddg redirect param back to the real URL', () {
    final results = const DdgResultParser().parse(_ddgHtml);

    expect(results, hasLength(2)); // the non-uddg "Settings" anchor is ignored
    expect(results[0].url, 'https://en.wikipedia.org/wiki/Cat');
    expect(results[0].title, 'Cat - Wikipedia');
    expect(results[1].url, 'https://example.com/kittens');
    // Tags stripped, &amp; decoded.
    expect(results[1].title, 'Kittens & more');
  });

  test('caps the number of results at maxResults', () {
    final results = const DdgResultParser(maxResults: 1).parse(_ddgHtml);
    expect(results, hasLength(1));
    expect(results.first.url, 'https://en.wikipedia.org/wiki/Cat');
  });

  test('returns nothing for HTML with no result links', () {
    expect(const DdgResultParser().parse('<html><body>no hits</body></html>'), isEmpty);
  });

  test('DdgSearchService url-encodes the query into the DDG-lite endpoint', () {
    final url = DdgSearchService.queryUrl('gatos naranjas & más');
    expect(url, startsWith('https://lite.duckduckgo.com/lite/?q='));
    expect(url, contains('gatos'));
    expect(url, isNot(contains(' '))); // spaces encoded, never raw
  });
}
