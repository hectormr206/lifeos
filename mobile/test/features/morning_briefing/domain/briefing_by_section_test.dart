// El boletín se lee por TEMA, no por feed.
//
// Medido el 2026-08-24 sobre las fuentes reales: 249 noticias frescas en un
// día. Con el tope de 10 POR FUENTE llegaban ~87 tarjetas, y el reparto salía
// torcido — La Jornada aportaba 108 y se llevaba 10, mientras Deportes aportaba
// 1 y Linux 3. El tope reflejaba qué feed publica más, no qué le importa al
// lector. Agrupar y topar por SECCIÓN arregla las dos cosas: BBC y NYT dejan de
// contar la misma historia dos veces en dos bloques, y ninguna fuente ruidosa
// se come su tema.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_assembler.dart';

final _now = DateTime(2026, 8, 24, 9);

ParsedFeedItem _item(String title, {int minutesAgo = 0}) => ParsedFeedItem(
      title: title,
      link: 'https://ejemplo.com/$title',
      description: 'detalle de $title',
      published: _now.subtract(Duration(minutes: minutesAgo)),
    );

SourceHarvest _harvest(String name, String section, List<String> titles) =>
    SourceHarvest(
      name: name,
      section: section,
      items: [
        for (var i = 0; i < titles.length; i++)
          _item(titles[i], minutesAgo: i),
      ],
    );

void main() {
  const assembler = BriefingAssembler();

  test('cada artículo sabe de qué sección viene', () {
    final briefing = assembler.assemble(
      [_harvest('BBC', 'Mundo', ['a'])],
      now: _now,
      generatedAt: _now,
    );
    expect(briefing.articles.single.section, 'Mundo');
  });

  test('las fuentes de un mismo tema caen en un solo bloque', () {
    final briefing = assembler.assemble([
      _harvest('BBC', 'Mundo', ['a1']),
      _harvest('Xataka', 'Tecnología', ['t1']),
      _harvest('NYT', 'Mundo', ['a2']),
    ], now: _now, generatedAt: _now);

    expect(briefing.sections.map((s) => s.section), ['Mundo', 'Tecnología']);
    expect(briefing.sections.first.articles, hasLength(2));
  });

  test('una fuente ruidosa no se come su sección', () {
    final briefing = assembler.assemble([
      _harvest('La Jornada', 'México', List.generate(40, (i) => 'j$i')),
      _harvest('Expansión', 'México', List.generate(40, (i) => 'e$i')),
    ], now: _now, generatedAt: _now);

    final mexico = briefing.sections.single.articles;
    final jornada = mexico.where((a) => a.sourceName == 'La Jornada').length;

    // Cuántas caben es el MENOR de los dos topes: lo que las fuentes pueden
    // aportar entre todas, o lo que el tema admite. Escrito así en vez de con
    // un número, porque los dos topes ya han cambiado tres veces en una semana
    // y cada vez dejaron esta prueba afirmando algo falso.
    expect(
      mexico,
      hasLength(
        [
          2 * BriefingAssembler.defaultPerSourceCap,
          BriefingAssembler.defaultSectionCap,
        ].reduce((a, b) => a < b ? a : b),
      ),
    );
    expect(
      jornada,
      lessThanOrEqualTo(BriefingAssembler.defaultPerSourceCap),
      reason: 'ninguna fuente pasa de su cuota dentro del tema',
    );
    expect(
      mexico.where((a) => a.sourceName == 'Expansión'),
      isNotEmpty,
      reason: 'la otra fuente del tema tiene que aparecer',
    );
  });

  test('las fuentes de un tema se intercalan, no se apilan', () {
    final briefing = assembler.assemble([
      _harvest('La Jornada', 'México', ['j1', 'j2', 'j3']),
      _harvest('Expansión', 'México', ['e1', 'e2', 'e3']),
    ], now: _now, generatedAt: _now);

    expect(
      briefing.sections.single.articles.take(2).map((a) => a.sourceName),
      ['La Jornada', 'Expansión'],
      reason: 'lo primero que se lee del tema viene de fuentes distintas',
    );
  });

  test('un tema con poco material se queda con lo que hay', () {
    final briefing = assembler.assemble([
      _harvest('Marca', 'Deportes', ['d1']),
    ], now: _now, generatedAt: _now);

    expect(briefing.sections.single.articles, hasLength(1));
  });

  test('el orden de las secciones es el de las fuentes configuradas', () {
    final briefing = assembler.assemble([
      _harvest('Marca', 'Deportes', ['d1']),
      _harvest('BBC', 'Mundo', ['m1']),
    ], now: _now, generatedAt: _now);

    expect(briefing.sections.map((s) => s.section), ['Deportes', 'Mundo']);
  });

  test('con tres fuentes ruidosas, el tope del TEMA es el que manda', () {
    // El caso real de Mundo el 2026-08-29: BBC 16, El País 118 y NYT 40
    // noticias frescas. Sin tope de tema serían veinticuatro tarjetas.
    final briefing = assembler.assemble([
      _harvest('BBC Mundo', 'Mundo', List.generate(40, (i) => 'b$i')),
      _harvest('El País', 'Mundo', List.generate(40, (i) => 'p$i')),
      _harvest('NYT', 'Mundo', List.generate(40, (i) => 'n$i')),
    ], now: _now, generatedAt: _now);

    final mundo = briefing.sections.single.articles;
    expect(mundo, hasLength(BriefingAssembler.defaultSectionCap));
    for (final fuente in ['BBC Mundo', 'El País', 'NYT']) {
      expect(
        mundo.where((a) => a.sourceName == fuente),
        isNotEmpty,
        reason: 'el recorte del tema no puede dejar fuera a una fuente entera',
      );
    }
  });
}
