// Proves the pragmatic, dependency-free source reader: RSS/Atom feeds yield
// item titles+summaries, arbitrary HTML is stripped to plain text, CDATA +
// entities are decoded, and unusable input is reported empty (so the pipeline
// can skip it).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';

void main() {
  _blankSpaceGuards();
  const extractor = SourceContentExtractor(maxItems: 3, maxChars: 500);

  test('extracts channel title + item titles/summaries from an RSS feed', () {
    const rss = '''
<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Noticias Ejemplo</title>
  <item><title>Primera noticia</title><description>Resumen de la primera.</description></item>
  <item><title><![CDATA[Segunda &amp; noticia]]></title><description><![CDATA[Detalle dos]]></description></item>
</channel></rss>''';

    final result = extractor.extract(rss, url: 'https://ejemplo.com/rss');

    expect(result.isEmpty, isFalse);
    expect(result.title, 'Noticias Ejemplo');
    expect(result.text, contains('Primera noticia'));
    expect(result.text, contains('Resumen de la primera.'));
    expect(result.text, contains('Segunda & noticia'));
    expect(result.text, contains('Detalle dos'));
  });

  test('extracts entries from an Atom feed', () {
    const atom = '''
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <entry><title>Entrada uno</title><summary>Sumario uno</summary></entry>
</feed>''';

    final result = extractor.extract(atom, url: 'https://ejemplo.com/atom');
    expect(result.title, 'Atom Feed');
    expect(result.text, contains('Entrada uno'));
    expect(result.text, contains('Sumario uno'));
  });

  test('strips HTML to plain text and takes the title', () {
    const html = '''
<html><head><title>Página de Noticias</title></head>
<body><script>var x = 1;</script><h1>Titular</h1>
<p>Primer párrafo con <b>negrita</b>.</p></body></html>''';

    final result = extractor.extract(html, url: 'https://ejemplo.com/articulo');
    expect(result.title, 'Página de Noticias');
    expect(result.text, contains('Titular'));
    // Tags are replaced with spaces, so inline `<b>` yields "negrita" as a
    // standalone word rather than glued to the surrounding text.
    expect(result.text, contains('Primer párrafo con negrita'));
    expect(result.text, isNot(contains('var x')), reason: 'script content is dropped');
    expect(result.text, isNot(contains('<')), reason: 'no raw tags remain');
  });

  test('caps extracted text length', () {
    final longBody = '<html><body><p>${'a' * 5000}</p></body></html>';
    final result = extractor.extract(longBody, url: 'https://ejemplo.com');
    expect(result.text.length, lessThanOrEqualTo(501), reason: 'maxChars 500 + ellipsis');
  });
}

// REPORTED: some briefing items render with a blank gap before the text —
// "arranca corrido", with nothing visible causing it.
//
// `trim()` and `\s+` between them handle ordinary whitespace, so anything that
// survives to the screen is a character that is NOT Unicode White_Space and
// therefore invisible to both. Feeds and small on-device models emit these:
// zero-width spaces, byte-order marks, braille blanks. They cannot be seen in
// the source, only in the rendering — which is exactly why this went unnoticed.
//
// Numeric HTML entities are the other half: the decoder handled a fixed list of
// named ones, so `&#160;` (a non-breaking space) reached the card as literal
// text instead of becoming a space that could then be trimmed.
void _blankSpaceGuards() {
  group('invisible leading blanks are stripped', () {
    final extractor = SourceContentExtractor();

    test('a zero-width space before the text does not indent the card', () {
      expect(extractor.cleanBrief('​Un vistazo al futuro'), 'Un vistazo al futuro');
    });

    test('a byte-order mark is not text', () {
      expect(extractor.cleanBrief('﻿Un vistazo'), 'Un vistazo');
    });

    test('a braille blank — invisible, and not Unicode whitespace', () {
      expect(extractor.cleanBrief('⠀⠀Un vistazo'), 'Un vistazo');
    });

    test('numeric entities become spaces, not literal text', () {
      expect(extractor.cleanBrief('&#160;&#160;Un vistazo'), 'Un vistazo');
      expect(extractor.cleanBrief('&#xA0;Un vistazo'), 'Un vistazo');
    });

    test('a mix of the above, as a real feed ships it', () {
      expect(
        extractor.cleanBrief('<p>​&#160; <img src="x.jpg"> Un vistazo al futuro</p>'),
        'Un vistazo al futuro',
      );
    });

    test('an entity INSIDE the text still decodes (no over-stripping)', () {
      expect(extractor.cleanBrief('Caf&#233; y t&#233;'), 'Café y té');
    });

    test('ordinary text is untouched', () {
      expect(extractor.cleanBrief('Un vistazo al futuro'), 'Un vistazo al futuro');
    });
  });
}
