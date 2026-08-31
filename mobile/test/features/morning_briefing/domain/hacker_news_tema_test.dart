// El lector el 2026-08-31: "me gustaría tener más noticias de Hacker News, es
// relevante para mí... antes teníamos 10".
//
// Medido: la API de HN devuelve 20 noticias, pero HN vivía DENTRO de Tecnología,
// compartiendo el cupo de 20 del tema con Xataka, Hipertextual y Microsiervos.
// Con el tope de 8 por fuente y el reparto entre cuatro, HN aportaba unas cinco:
// bajó respecto a las diez de antes, no subió.
//
// Subir el tope por fuente arreglaría HN y estropearía lo demás — dejaría que
// Récord (28 noticias al día) y La Jornada (98) se coman sus temas. Un tema
// propio le da su cupo entero y su propio resumen, y de paso deja de diluirse
// dentro del de Tecnología.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_assembler.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_harvester.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';

final _now = DateTime(2026, 8, 31, 8);

SourceHarvest _harvest(String name, String section, int cuantas) => SourceHarvest(
      name: name,
      section: section,
      items: [
        for (var i = 1; i <= cuantas; i++)
          ParsedFeedItem(
            title: '$name noticia $i',
            link: 'https://ejemplo.com/${name.hashCode}/$i',
            published: _now.subtract(const Duration(hours: 1)),
          ),
      ],
    );

void main() {
  test('Hacker News tiene tema propio, no comparte el de Tecnología', () {
    expect(hackerNewsSection, isNot('Tecnología'));
  });

  test('con tema propio, HN aporta muchas más que compartiendo', () {
    const assembler = BriefingAssembler();

    final briefing = assembler.assemble([
      _harvest('Xataka', 'Tecnología', 20),
      _harvest('Hipertextual', 'Tecnología', 20),
      _harvest('Microsiervos', 'Tecnología', 20),
      _harvest('Hacker News', hackerNewsSection, 20),
    ], now: _now, generatedAt: _now);

    final hn = briefing.articles.where((a) => a.sourceName == 'Hacker News');
    expect(
      hn.length,
      greaterThanOrEqualTo(8),
      reason: 'sin competir por el cupo, HN llega a su tope por fuente entero',
    );

    final temas = briefing.sections.map((s) => s.section).toList();
    expect(temas, contains(hackerNewsSection));
    expect(temas, contains('Tecnología'));
  });

  test('Tecnología recupera el sitio que HN le ocupaba', () {
    const assembler = BriefingAssembler();

    final briefing = assembler.assemble([
      _harvest('Xataka', 'Tecnología', 20),
      _harvest('Hipertextual', 'Tecnología', 20),
      _harvest('Microsiervos', 'Tecnología', 20),
      _harvest('Hacker News', hackerNewsSection, 20),
    ], now: _now, generatedAt: _now);

    final tec = briefing.sections.firstWhere((s) => s.section == 'Tecnología');
    expect(
      tec.articles,
      hasLength(BriefingAssembler.defaultSectionCap),
      reason: 'sus tres fuentes se reparten el tema entero, sin un cuarto invitado',
    );
  });
}
