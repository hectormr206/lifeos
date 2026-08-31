// Lo que pidió el usuario el 2026-08-31: "el resumen es muy corto... necesito
// que abarque TODAS las noticias y una buena parte de cada una, sin excepción",
// para enterarse de qué pasa y por qué sin abrir la pestaña.
//
// Tal como estaba era imposible: la sección trae hasta 20 noticias y al modelo
// sólo se le enseñaban 12, así que ocho no se miraban nunca; y la salida se
// cortaba a 420 caracteres, tres frases para veinte noticias.
//
// El techo real es del motor: 512 tokens por llamada, que no se pueden subir
// desde aquí. Por eso el resumen se escribe POR TANDAS y se concatena — cubrir
// veinte noticias en una sola respuesta no cabe.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/section_digest_writer.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

OnDeviceBriefing _conNoticias(int cuantas) => OnDeviceBriefing(
      generatedAt: DateTime(2026, 8, 31, 8),
      articles: [
        for (var i = 1; i <= cuantas; i++)
          BriefingArticle(
            sourceName: 'Fuente',
            section: 'Mundo',
            title: 'Titular número $i',
            url: 'https://ejemplo.com/$i',
            description: 'Lo que cuenta la noticia $i, con su porqué.',
          ),
      ],
    );

void main() {
  test('ninguna noticia se queda fuera de lo que ve el modelo', () async {
    final prompts = <String>[];
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (p) {
        prompts.add(p);
        return 'Un párrafo que cuenta qué pasó y por qué.';
      },
    );

    await BriefingSectionDigestWriter(engine: engine)
        .fillDigests(_conNoticias(20));

    final todo = prompts.join('\n');
    for (var i = 1; i <= 20; i++) {
      expect(
        todo,
        contains('Titular número $i'),
        reason: 'la noticia $i tiene que llegar al modelo; "sin excepción" '
            'quiere decir sin excepción',
      );
    }
  });

  test('veinte noticias se escriben por TANDAS, no en una sola llamada', () {
    // El motor corta a 512 tokens de salida. Pedirle veinte noticias en una
    // respuesta devuelve un párrafo truncado, no un resumen completo.
    expect(
      BriefingSectionDigestWriter.articlesPerPass,
      lessThan(20),
      reason: 'una tanda tiene que caber en el techo del motor',
    );
  });

  test('el resumen de una sección larga es largo de verdad', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => 'Frase que cuenta qué pasó y por qué importa, con detalle '
          'suficiente para no tener que abrir la noticia. ' * 3,
    );

    final resultado = await BriefingSectionDigestWriter(engine: engine)
        .fillDigests(_conNoticias(20));

    final texto = resultado.sectionDigests['Mundo']!;
    expect(
      texto.length,
      greaterThan(800),
      reason: 'con veinte noticias, 420 caracteres no cuentan nada',
    );
  });

  test('una tanda que falla no se lleva a las demás', () async {
    var llamada = 0;
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) {
        llamada++;
        if (llamada == 2) return ''; // el modelo se atragantó en esta tanda
        return 'Lo que pasó en estas noticias, y por qué.';
      },
    );

    final resultado = await BriefingSectionDigestWriter(engine: engine)
        .fillDigests(_conNoticias(20));

    expect(
      resultado.sectionDigests['Mundo'],
      isNotNull,
      reason: 'cobertura parcial es mucho mejor que ninguna',
    );
  });

  test('una sección corta sigue saliendo en una sola tanda', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => 'Lo que pasó hoy en este tema.',
    );

    await BriefingSectionDigestWriter(engine: engine).fillDigests(_conNoticias(3));

    expect(engine.generateCount, 1);
  });
}
