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
}
