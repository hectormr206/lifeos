// Dos cosechas con el mismo nombre son UNA fuente.
//
// Medido el 2026-08-20: BBC retiró su feed de ciencia y esa URL responde 301
// al feed general. Dos entradas distintas en la lista acaban descargando el
// mismo XML, así que el boletín mostraba "BBC Mundo" dos veces con las mismas
// noticias. Quitar el feed muerto de los valores por defecto no arregla los
// dispositivos que ya lo tienen guardado: la fusión sí.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_assembler.dart';

ParsedFeedItem item(String title, DateTime published, {String? link}) =>
    ParsedFeedItem(
      title: title,
      link: link ?? 'https://x.com/${title.hashCode}',
      published: published,
    );

void main() {
  final now = DateTime(2026, 8, 20, 9);
  final hoy = DateTime(2026, 8, 20, 7);
  const assembler = BriefingAssembler();

  group('fuentes repetidas en el boletín', () {
    test('el mismo nombre dos veces sale una sola vez', () {
      final b = assembler.assemble([
        SourceHarvest(name: 'BBC Mundo', items: [item('A', hoy)]),
        SourceHarvest(name: 'BBC Mundo', items: [item('B', hoy)]),
      ], now: now, generatedAt: now);

      final fuentes = b.articles.map((a) => a.sourceName).toSet();
      expect(fuentes, {'BBC Mundo'});
    });

    test('la misma noticia no se repite al fusionar', () {
      // Redirigen al mismo feed: los artículos son idénticos, y verlos dos
      // veces es exactamente lo que el usuario reportó.
      final b = assembler.assemble([
        SourceHarvest(
            name: 'BBC Mundo', items: [item('Titular', hoy, link: 'https://bbc/1')]),
        SourceHarvest(
            name: 'BBC Mundo', items: [item('Titular', hoy, link: 'https://bbc/1')]),
      ], now: now, generatedAt: now);

      expect(b.articles, hasLength(1));
    });

    test('noticias distintas del mismo nombre se conservan las dos', () {
      final b = assembler.assemble([
        SourceHarvest(name: 'BBC Mundo', items: [item('A', hoy)]),
        SourceHarvest(name: 'BBC Mundo', items: [item('B', hoy)]),
      ], now: now, generatedAt: now);

      expect(b.articles.map((a) => a.title), containsAll(['A', 'B']));
    });

    test('el tope por fuente se aplica al total fusionado, no a cada mitad', () {
      // Si no, dos entradas duplicadas darían el doble de noticias que una.
      const capped = BriefingAssembler(perSourceCap: 3);
      final b = capped.assemble([
        SourceHarvest(
            name: 'BBC Mundo',
            items: [for (var i = 0; i < 5; i++) item('a$i', hoy)]),
        SourceHarvest(
            name: 'BBC Mundo',
            items: [for (var i = 0; i < 5; i++) item('b$i', hoy)]),
      ], now: now, generatedAt: now);

      expect(b.articles, hasLength(3));
    });

    test('nombres distintos siguen siendo fuentes distintas', () {
      final b = assembler.assemble([
        SourceHarvest(name: 'BBC Mundo', items: [item('A', hoy)]),
        SourceHarvest(name: 'El País', items: [item('B', hoy)]),
      ], now: now, generatedAt: now);

      expect(b.articles.map((a) => a.sourceName).toSet(), hasLength(2));
    });

    test('si una copia falla y la otra trae noticias, la fuente NO se salta', () {
      // Una entrada muerta y una viva bajo el mismo nombre: el usuario tiene
      // sus noticias, y decirle "sin novedades" sería mentira.
      final b = assembler.assemble([
        SourceHarvest(name: 'BBC Mundo', failed: true),
        SourceHarvest(name: 'BBC Mundo', items: [item('A', hoy)]),
      ], now: now, generatedAt: now);

      expect(b.articles, hasLength(1));
      expect(b.skippedSources, isNot(contains('BBC Mundo')));
    });

    test('una fuente saltada no se nombra dos veces', () {
      final b = assembler.assemble([
        SourceHarvest(name: 'BBC Mundo', failed: true),
        SourceHarvest(name: 'BBC Mundo', failed: true),
      ], now: now, generatedAt: now);

      expect(b.skippedSources.where((s) => s == 'BBC Mundo'), hasLength(1));
    });
  });
}
