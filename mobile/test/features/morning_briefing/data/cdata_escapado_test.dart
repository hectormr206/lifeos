// El usuario vio títulos así el 2026-08-31:
//   <![CDATA[Mateo logra sueño universitario; mantiene puntaje de excelencia]]>
//
// Vienen de Excélsior, una de las fuentes que se añadieron el 2026-08-29. Su
// feed manda el CDATA ESCAPADO como entidades —`&lt;![CDATA[…]]&gt;`— en vez de
// CDATA de verdad. El limpiador desenvolvía CDATA y DESPUÉS decodificaba
// entidades, así que el marcado reaparecía justo cuando ya nadie iba a mirarlo.
//
// Bytes reales del feed, no inventados.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';

const _extractor = SourceContentExtractor();
const _url = 'https://www.excelsior.com.mx/rss/adrenalina';

String _feed(String title) => '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>RSS::excelsior.com.mx - Portada</title>
  <item>
    <title>$title</title>
    <link>https://www.excelsior.com.mx/nota/1</link>
    <pubDate>Sun, 31 Aug 2026 07:00:00 -0600</pubDate>
    <description>&lt;![CDATA[Lo que cuenta la nota.]]&gt;</description>
  </item>
</channel></rss>''';

void main() {
  test('un CDATA escapado no llega al título del lector', () {
    final items = _extractor.parseFeed(
      _feed('&lt;![CDATA[Mateo logra sueño universitario; mantiene puntaje]]&gt;'),
      url: _url,
    );

    expect(items.items, hasLength(1));
    expect(items.items.single.title, 'Mateo logra sueño universitario; mantiene puntaje');
    expect(items.items.single.title, isNot(contains('CDATA')));
  });

  test('tampoco al resumen de la tarjeta', () {
    final items = _extractor.parseFeed(_feed('Un titular normal'), url: _url);

    expect(items.items.single.description, isNot(contains('CDATA')));
    expect(items.items.single.description, contains('Lo que cuenta la nota.'));
  });

  test('el CDATA de verdad sigue funcionando igual', () {
    final items = _extractor.parseFeed(
      _feed('<![CDATA[Un titular con CDATA de verdad]]>'),
      url: _url,
    );

    expect(items.items.single.title, 'Un titular con CDATA de verdad');
  });

  test('un titular sin nada raro no se toca', () {
    final items = _extractor.parseFeed(_feed('Olmecas vence a Pericos'), url: _url);

    expect(items.items.single.title, 'Olmecas vence a Pericos');
  });
}
