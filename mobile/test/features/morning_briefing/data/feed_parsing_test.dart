// Proves the STRUCTURED per-item feed parser (parseFeed) handles RSS, Atom and
// RDF, extracts title/link/description/published, parses RFC-822 + ISO-8601
// dates, and that the Hacker News Algolia adapters parse candidates + comments.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';

void main() {
  const extractor = SourceContentExtractor();

  test('parses RSS items: title, link, description, pubDate', () {
    const rss = '''
<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Noticias RSS</title>
  <item>
    <title>Primera</title>
    <link>https://ex.com/1</link>
    <description><![CDATA[Resumen &amp; detalle]]></description>
    <pubDate>Wed, 22 Jul 2026 11:47:59 GMT</pubDate>
  </item>
</channel></rss>''';

    final feed = extractor.parseFeed(rss, url: 'https://ex.com/rss');
    expect(feed.sourceTitle, 'Noticias RSS');
    expect(feed.items.length, 1);
    final item = feed.items.single;
    expect(item.title, 'Primera');
    expect(item.link, 'https://ex.com/1');
    expect(item.description, 'Resumen & detalle');
    expect(item.published, DateTime.utc(2026, 7, 22, 11, 47, 59));
  });

  test('parses Atom entries: href link + summary + updated (ISO-8601)', () {
    const atom = '''
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <entry>
    <title>Entrada uno</title>
    <link rel="alternate" href="https://ex.com/atom/1"/>
    <summary>Sumario uno</summary>
    <updated>2026-07-22T08:30:00Z</updated>
  </entry>
</feed>''';

    final feed = extractor.parseFeed(atom, url: 'https://ex.com/atom');
    expect(feed.sourceTitle, 'Atom Feed');
    final item = feed.items.single;
    expect(item.title, 'Entrada uno');
    expect(item.link, 'https://ex.com/atom/1');
    expect(item.description, 'Sumario uno');
    expect(item.published, DateTime.utc(2026, 7, 22, 8, 30, 0));
  });

  test('parses RDF items: link text + dc:date', () {
    const rdf = '''
<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns="http://purl.org/rss/1.0/"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel><title>RDF Feed</title></channel>
  <item rdf:about="https://ex.com/rdf/1">
    <title>Item RDF</title>
    <link>https://ex.com/rdf/1</link>
    <description>Desc RDF</description>
    <dc:date>2026-07-21T10:00:00+00:00</dc:date>
  </item>
</rdf:RDF>''';

    final feed = extractor.parseFeed(rdf, url: 'https://ex.com/rdf');
    expect(feed.sourceTitle, 'RDF Feed');
    final item = feed.items.single;
    expect(item.title, 'Item RDF');
    expect(item.link, 'https://ex.com/rdf/1');
    expect(item.published, DateTime.utc(2026, 7, 21, 10, 0, 0));
  });

  test('parseFeedDate handles RFC-822 with a numeric offset', () {
    // +0200 → UTC is two hours earlier.
    expect(
      SourceContentExtractor.parseFeedDate('Tue, 21 Jul 2026 12:00:00 +0200'),
      DateTime.utc(2026, 7, 21, 10, 0, 0),
    );
    expect(SourceContentExtractor.parseFeedDate(''), isNull);
    expect(SourceContentExtractor.parseFeedDate('not a date'), isNull);
  });

  test('parses Hacker News Algolia front-page candidates', () {
    const body = '''
{"hits":[
  {"objectID":"100","title":"Story A","url":"https://ext.com/a","created_at":"2026-07-22T09:00:00.000Z"},
  {"objectID":"101","title":"Ask HN: text post","created_at":"2026-07-22T10:00:00.000Z"}
]}''';

    final feed = extractor.parseHackerNews(body);
    expect(feed.items.length, 2);
    expect(feed.items[0].hnObjectId, '100');
    expect(feed.items[0].link, 'https://ext.com/a');
    // No url → falls back to the HN item page built from objectID.
    expect(feed.items[1].link, 'https://news.ycombinator.com/item?id=101');
    expect(feed.items[1].published, DateTime.utc(2026, 7, 22, 10, 0, 0));
  });

  test('brief description: strips escaped HTML, decodes entities, caps to 200', () {
    // Simon-Willison-style feed: the <description> ships ESCAPED HTML, so the
    // tags only reappear after entity-decoding — they must still be stripped,
    // and the (long) result capped with an ellipsis.
    final body = StringBuffer('<rss version="2.0"><channel><title>SW</title><item>'
        '<title>Post</title><link>https://sw.com/1</link><description>');
    body.write('&lt;p&gt;Hola &amp;amp; ');
    body.write('bienvenido. ' * 60); // long text to force the cap
    body.write('&lt;/p&gt;</description>'
        '<pubDate>Wed, 22 Jul 2026 11:00:00 GMT</pubDate></item></channel></rss>');

    final feed = extractor.parseFeed(body.toString(), url: 'https://sw.com/rss');
    final desc = feed.items.single.description;

    expect(desc, isNot(contains('<')), reason: 'escaped tags stripped after decoding');
    expect(desc, isNot(contains('&lt;')));
    expect(desc, isNot(contains('&amp;')));
    expect(desc, contains('Hola & bienvenido'));
    expect(desc.length, lessThanOrEqualTo(201)); // 200 chars + the ellipsis
    expect(desc.endsWith('…'), isTrue, reason: 'capped with an ellipsis');
  });

  test('brief cleanBrief keeps short plain text unchanged (no ellipsis)', () {
    expect(extractor.cleanBrief('Texto breve y claro'), 'Texto breve y claro');
    expect(extractor.cleanBrief('<![CDATA[Resumen &amp; detalle]]>'), 'Resumen & detalle');
  });

  test('extractHnComments flattens first-level comments', () {
    const body = '''
{"children":[
  {"author":"alice","text":"<p>Buen punto &amp; claro</p>"},
  {"author":"bob","text":"En desacuerdo"}
]}''';

    final text = extractor.extractHnComments(body);
    expect(text, contains('alice: Buen punto & claro'));
    expect(text, contains('bob: En desacuerdo'));
    expect(text, isNot(contains('<p>')));
  });
}
