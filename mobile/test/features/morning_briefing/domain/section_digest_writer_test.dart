// El resumen del tema es para DECIDIR, no para sustituir la noticia.
//
// Con 249 noticias frescas en un día, leer tarjeta por tarjeta es inviable. El
// usuario lo pidió así: "leo ese resumen completo y decido si irme a leer la
// que sea de mi agrado o continúo con el siguiente". Por eso hay un párrafo por
// tema, escrito en el teléfono a partir de los titulares que ya se descargaron.
//
// Y por eso NO se inventa: si el modelo no está o falla, el tema se queda sin
// párrafo y el lector ve los titulares. Un resumen falso es peor que ninguno.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/section_digest_writer.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

BriefingArticle _a(String title, String section, {String desc = 'detalle'}) =>
    BriefingArticle(
      sourceName: 'F',
      section: section,
      title: title,
      url: 'https://ejemplo.com/$title',
      description: desc,
    );

OnDeviceBriefing _briefing(List<BriefingArticle> articles) =>
    OnDeviceBriefing(articles: articles, generatedAt: DateTime(2026, 8, 24));

void main() {
  test('escribe un párrafo por tema, no uno por fuente', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Lo que pasó hoy.');
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(
      _briefing([
        _a('m1', 'Mundo'),
        _a('m2', 'Mundo'),
        _a('t1', 'Tecnología'),
      ]),
    );

    expect(out.sectionDigests.keys, unorderedEquals(['Mundo', 'Tecnología']));
    expect(engine.prompts, hasLength(2));
  });

  test('el modelo ve los titulares del tema, no una noticia suelta', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Resumen.');
    final writer = BriefingSectionDigestWriter(engine: engine);

    await writer.fillDigests(_briefing([_a('cumbre', 'Mundo'), _a('elecciones', 'Mundo')]));

    expect(engine.prompts.single, contains('cumbre'));
    expect(engine.prompts.single, contains('elecciones'));
  });

  test('sin modelo NO hay párrafo inventado', () async {
    final engine = FakeLocalLlmEngine(installed: false, loadShouldFail: true);
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(_briefing([_a('m1', 'Mundo')]));

    expect(out.sectionDigests, isEmpty);
    expect(out.articles, hasLength(1), reason: 'las noticias siguen ahí');
  });

  test('si un tema falla, los demás conservan el suyo', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (prompt) {
        if (prompt.contains('rompe')) throw Exception('este tema rompe');
        return 'Resumen.';
      },
    );
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(
      _briefing([_a('rompe', 'Mundo'), _a('t1', 'Tecnología')]),
    );

    expect(out.sectionDigests.containsKey('Mundo'), isFalse);
    expect(out.sectionDigests['Tecnología'], 'Resumen.');
  });

  test('una respuesta vacía no se guarda como resumen', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => '   ');
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(_briefing([_a('m1', 'Mundo')]));

    expect(out.sectionDigests, isEmpty);
  });

  test('el párrafo se recorta si el modelo se pasa de largo', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => 'x' * (BriefingSectionDigestWriter.maxDigestChars + 200),
    );
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(_briefing([_a('m1', 'Mundo')]));

    expect(
      out.sectionDigests['Mundo']!.length,
      lessThanOrEqualTo(BriefingSectionDigestWriter.maxDigestChars + 1),
    );
  });

  test('un boletín sin noticias no llama al modelo', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Resumen.');
    final writer = BriefingSectionDigestWriter(engine: engine);

    await writer.fillDigests(_briefing([]));

    expect(engine.prompts, isEmpty);
  });

  test('el resumen sobrevive al guardado y la relectura', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Lo de hoy.');
    final writer = BriefingSectionDigestWriter(engine: engine);

    final out = await writer.fillDigests(_briefing([_a('m1', 'Mundo')]));
    final again = OnDeviceBriefing.decode(out.encode());

    expect(again!.sectionDigests['Mundo'], 'Lo de hoy.');
  });
}
