// El resumen por tema se cortaba a media palabra ("hay discusiones so…"), que
// es peor que una frase de menos: deja al lector sin saber si la idea seguía.
// Y algunos abrían con relleno ("Las noticias cubren diversos temas…") en vez
// de con la noticia, gastando la primera línea, que es la que decide si lee.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/section_digest_writer.dart';

void main() {
  test('un resumen corto se deja tal cual', () {
    const text = 'Dos frases cortas. Nada que recortar.';
    expect(BriefingSectionDigestWriter.clip(text), text);
  });

  test('se corta en la última frase COMPLETA, nunca a media palabra', () {
    final long = '${'Primera frase completa que cabe entera. ' * 9}'
        'Y esta última se pasa del límite y no debería aparecer a medias';

    final clipped = BriefingSectionDigestWriter.clip(long);

    expect(clipped.length, lessThanOrEqualTo(BriefingSectionDigestWriter.maxDigestChars));
    expect(clipped.endsWith('.'), isTrue, reason: 'termina en una frase cerrada');
    expect(clipped, isNot(contains('…')), reason: 'no hay corte a media palabra');
    expect(clipped.contains('y no debería aparecer'), isFalse);
  });

  test('sin ningún punto donde cortar, corta en la última palabra entera', () {
    final sinPuntos = 'palabra ' * 200;

    final clipped = BriefingSectionDigestWriter.clip(sinPuntos);

    expect(clipped.length, lessThanOrEqualTo(BriefingSectionDigestWriter.maxDigestChars + 1));
    expect(clipped.endsWith('…'), isTrue);
    expect(
      clipped.substring(0, clipped.length - 1).trim().endsWith('palabra'),
      isTrue,
      reason: 'la última palabra queda entera',
    );
  });

  test('los cierres de frase con ? y ! también valen', () {
    final long = '${'¿Qué está pasando aquí? ' * 15}'
        '${'Una cola larguísima que se pasa del límite permitido y sobra. ' * 3}';

    final clipped = BriefingSectionDigestWriter.clip(long);

    expect(clipped.endsWith('?'), isTrue);
  });

  test('el prompt pide empezar por la noticia, no por relleno', () {
    final prompt = BriefingSectionDigestWriter.promptFor(
      section: 'Tecnología',
      lines: '- Titular uno (Fuente)\n',
    );

    expect(prompt, contains('Empieza directamente por la noticia'));
    expect(prompt.toLowerCase(), contains('no empieces'));
  });
}
