// Proves the per-source translation stage.
//
// THE REPORTED BUG: "some news items don't get translated". Two causes lived
// here. One is fixed in OnDeviceTranslator (bounded batches + per-slot retry).
// The other is this file's: the same-language check read ONE SAMPLE of the
// whole source and, if that sample looked Spanish, skipped EVERY article in it
// — so a single Spanish item in a mostly-English feed left the rest untouched.
// The decision belongs to each article.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/on_device_translator.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_translation.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

BriefingTranslationPipeline _pipeline(FakeLocalLlmEngine engine) => BriefingTranslationPipeline(
      translator: OnDeviceTranslator(engine),
      extractor: const SourceContentExtractor(),
    );

OnDeviceBriefing _briefing(List<BriefingArticle> articles) =>
    OnDeviceBriefing(generatedAt: DateTime(2026, 8, 10, 8), articles: articles);


/// Echoes each numbered input line with an "ES " prefix.
String _spanishEcho(String prompt) {
  final buffer = StringBuffer();
  for (final m in RegExp(r'^(\d+)\. (.*)$', multiLine: true).allMatches(prompt)) {
    buffer.writeln('${m.group(1)}. ES ${m.group(2)}');
  }
  return buffer.toString();
}

/// [count] English articles in reading order.
List<BriefingArticle> _english(int count) => [
      for (var i = 1; i <= count; i++)
        BriefingArticle(
          sourceName: 'English Source',
          title: 'The story number $i of the day',
          url: 'https://en.com/$i',
          description: 'It is a story about the number $i and the world',
        ),
    ];

void main() {
  test('a source mixing languages still translates its foreign items', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => '1. El futuro de la IA ||| Un vistazo al futuro',
    );
    final briefing = _briefing(const [
      // Already Spanish: left exactly as it is.
      BriefingArticle(
        sourceName: 'Mixta',
        title: 'La economía de España crece hoy por la mañana',
        url: 'https://m.com/1',
        description: 'El informe de hoy dice que la economía crece por las exportaciones',
      ),
      // English, in the same source: must NOT be skipped along with it.
      BriefingArticle(
        sourceName: 'Mixta',
        title: 'The Future of AI',
        url: 'https://m.com/2',
        description: 'A look at the future',
      ),
    ]);

    final out = await _pipeline(engine).translateSource(briefing, 'Mixta', 'es');

    expect(out.articles[0].translatedTitle, isNull, reason: 'already in Spanish, left alone');
    expect(out.articles[0].displayTitle, 'La economía de España crece hoy por la mañana');
    expect(out.articles[1].displayTitle, 'El futuro de la IA',
        reason: 'the English item in a mixed source is translated, not skipped');
  });

  test('a source entirely in the target language costs no model call at all', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final briefing = _briefing(const [
      BriefingArticle(
        sourceName: 'Española',
        title: 'La economía de España crece hoy',
        url: 'https://e.com/1',
        description: 'El informe de hoy lo confirma para las exportaciones del país',
      ),
    ]);

    await _pipeline(engine).translateSource(briefing, 'Española', 'es');

    expect(engine.loadCount, 0);
    expect(engine.generateCount, 0);
  });

  test('a translated item never comes back blank', () async {
    // The model answers with an empty line for the only item.
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => '1.');
    final briefing = _briefing(const [
      BriefingArticle(
        sourceName: 'English Source',
        title: 'The Future of AI',
        url: 'https://en.com/1',
        description: 'A look at the future',
      ),
    ]);

    final out = await _pipeline(engine).translateSource(briefing, 'English Source', 'es');

    expect(out.articles.single.displayTitle, 'The Future of AI',
        reason: 'native fallback, never an empty headline');
  });

  // ─── TRADUCIR MIENTRAS SE LEE ────────────────────────────────────────────
  //
  // La traducción salió del segundo plano (donde competía por el presupuesto de
  // los resúmenes y perdía en silencio) y vive en la apertura del boletín. Su
  // contrato es distinto: publica por lotes, en orden de lectura, y para en
  // cuanto el lector se va.
  group('translateInReadingOrder', () {
    test('publica por lotes, en el ORDEN en que se lee', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: _spanishEcho);
      final briefing = _briefing(_english(6));
      final publicados = <int>[];

      final out = await _pipeline(engine).translateInReadingOrder(
        briefing,
        languageCode: 'es',
        onBatch: (updated) async {
          publicados.add(
            updated.articles.where((a) => a.translatedTitle != null).length,
          );
          return updated;
        },
      );

      expect(publicados.length, 2, reason: 'seis noticias en lotes de cuatro');
      expect(publicados, [4, 6], reason: 'primero las de arriba');
      expect(
        out.articles.map((a) => a.displayTitle),
        everyElement(startsWith('ES ')),
      );
    });

    test('deja de pedir en cuanto shouldContinue dice que no', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: _spanishEcho);
      var seguir = true;
      final publicados = <OnDeviceBriefing>[];

      await _pipeline(engine).translateInReadingOrder(
        _briefing(_english(12)),
        languageCode: 'es',
        shouldContinue: () => seguir,
        onBatch: (updated) async {
          publicados.add(updated);
          seguir = false; // el lector se va tras el primer lote
          return updated;
        },
      );

      expect(publicados, hasLength(1));
      expect(
        engine.generateCount,
        1,
        reason: 'ni una llamada más al modelo después de irse',
      );
    });

    test('lo ya traducido y lo que ya está en el idioma no cuesta nada', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: _spanishEcho);
      final briefing = _briefing(const [
        BriefingArticle(
          sourceName: 'Española',
          title: 'La economía de España crece hoy por la mañana',
          url: 'https://es.com/1',
          description: 'El informe de hoy dice que la economía crece',
        ),
        BriefingArticle(
          sourceName: 'English Source',
          title: 'A story already translated',
          url: 'https://en.com/9',
          description: 'It is about the world',
          translatedTitle: 'Una historia ya traducida',
        ),
      ]);

      var lotes = 0;
      await _pipeline(engine).translateInReadingOrder(
        briefing,
        languageCode: 'es',
        onBatch: (updated) async {
          lotes++;
          return updated;
        },
      );

      expect(engine.generateCount, 0);
      expect(lotes, 0);
    });

    test('un motor que no carga deja los originales y DICE por qué', () async {
      final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
      Object? aviso;

      final out = await _pipeline(engine).translateInReadingOrder(
        _briefing(_english(2)),
        languageCode: 'es',
        onEngineFailure: (detail) => aviso = detail,
        onBatch: (updated) async => updated,
      );

      expect(out.articles.first.translatedTitle, isNull);
      expect(aviso, isNotNull, reason: 'texto sin traducir SIEMPRE con su causa');
    });

    test('cada lote pasa por el runBatch del llamante (la cola compartida)', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: _spanishEcho);
      var envueltos = 0;

      await _pipeline(engine).translateInReadingOrder(
        _briefing(_english(6)),
        languageCode: 'es',
        runBatch: (job) {
          envueltos++;
          return job();
        },
        onBatch: (updated) async => updated,
      );

      expect(
        envueltos,
        2,
        reason: 'una ranura de cola POR LOTE: un resumen que el lector pide '
            'espera cuatro noticias, no el boletín entero',
      );
    });
  });

}
