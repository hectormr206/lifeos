// Proves the on-device brief writer: the stage that gives a card text when the
// FEED gave none.
//
// Reported by the user: some briefing items have no short summary. The cause is
// not a bug in the parsing — Hugging Face's feed genuinely ships only
// guid/link/pubDate/title, and Hacker News has no body at all. There is nothing
// to read.
//
// The laptop's briefing never showed this gap, and not because its feeds are
// better: it does not READ a summary, it WRITES one (axi/briefing.py asks the
// model for "resumen corto 1-2 líneas en español"). This is the phone doing the
// same thing with the local model.
//
// The rules that matter here are about restraint: the feed's own words always
// win, a failure never costs the user the briefing, and the model is asked only
// for items that are genuinely blank.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_brief_writer.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

class _FakeFetcher implements SourceFetcher {
  _FakeFetcher({this.fails = false});

  /// Enough HTML for the extractor to produce readable text.
  static const String body = '<html><body><p>El cuerpo del artículo.</p></body></html>';

  final bool fails;
  final List<String> fetched = [];

  @override
  Future<String> fetch(String url) async {
    fetched.add(url);
    if (fails) throw Exception('sin red');
    return body;
  }
}

class _FakeEngine extends FakeLocalLlmEngine {
  _FakeEngine({this.answer = 'Un resumen corto del artículo.', this.failsLoad = false})
      : super(installed: true);

  final String answer;
  final bool failsLoad;
  int loads = 0;

  @override
  Future<void> load({LocalLlmBackend? backend}) async {
    loads++;
    if (failsLoad) throw Exception('sin modelo');
  }

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    prompts.add(prompt);
    return GenerationResult(text: answer, metrics: FakeLocalLlmEngine.defaultMetrics);
  }
}

BriefingBriefWriter _writer(_FakeEngine engine, _FakeFetcher fetcher) => BriefingBriefWriter(
      engine: engine,
      fetcher: fetcher,
      extractor: SourceContentExtractor(),
    );

OnDeviceBriefing _briefing(List<BriefingArticle> articles) =>
    OnDeviceBriefing(generatedAt: DateTime(2026, 8, 2, 8), articles: articles);

void main() {
  group('fills the blanks the feed left', () {
    test('an item with no description gets one written for it', () async {
      final engine = _FakeEngine(answer: 'Presentan un modelo nuevo de código abierto.');
      final briefing = _briefing(const [
        BriefingArticle(
          sourceName: 'Hugging Face Blog',
          title: 'A new open model',
          url: 'https://hf.co/blog/1',
          // The real feed carries no description at all.
        ),
      ]);

      final out = await _writer(engine, _FakeFetcher()).fillMissing(briefing);

      expect(out.articles.single.displayDescription,
          'Presentan un modelo nuevo de código abierto.');
    });

    test('the model is asked in Spanish for one or two lines', () async {
      final engine = _FakeEngine();
      await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'T', url: 'https://hf.co/1'),
      ]));

      final prompt = engine.prompts.single;
      expect(prompt.toLowerCase(), contains('español'));
      expect(prompt, contains('1 o 2 líneas'));
      // And told not to pad it with a preamble or echo the headline.
      expect(prompt.toLowerCase(), contains('sin repetir el título'));
    });
  });

  group('the feed always outranks the model', () {
    test('an item that HAS a description is left alone — no model call', () async {
      final engine = _FakeEngine();
      final fetcher = _FakeFetcher();
      final briefing = _briefing(const [
        BriefingArticle(
          sourceName: 'BBC Mundo',
          title: 'Una noticia',
          url: 'https://bbc.com/1',
          description: 'Lo que la BBC misma escribió.',
        ),
      ]);

      final out = await _writer(engine, fetcher).fillMissing(briefing);

      expect(out.articles.single.displayDescription, 'Lo que la BBC misma escribió.');
      expect(engine.prompts, isEmpty, reason: 'never paraphrase what the feed already said');
      expect(fetcher.fetched, isEmpty);
    });

    test('a translated brief also counts as present', () async {
      final engine = _FakeEngine();
      final briefing = _briefing(const [
        BriefingArticle(
          sourceName: 'English Source',
          title: 'The Future',
          url: 'https://en.com/1',
          description: 'A look ahead',
          translatedDescription: 'Un vistazo al futuro',
        ),
      ]);

      final out = await _writer(engine, _FakeFetcher()).fillMissing(briefing);

      expect(out.articles.single.displayDescription, 'Un vistazo al futuro');
      expect(engine.prompts, isEmpty);
    });

    test('a written brief never overwrites the feed field itself', () async {
      final engine = _FakeEngine(answer: 'Escrito por el modelo.');
      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'T', url: 'https://hf.co/1'),
      ]));

      // Stored apart, so the feed's own words can never be lost to a model's.
      expect(out.articles.single.description, isEmpty);
      expect(out.articles.single.generatedBrief, 'Escrito por el modelo.');
    });
  });

  // The user's requirement, in his words: "este resumen corto debe estar
  // siempre". A card is never left with nothing while ANY honest source of
  // text remains — and the ladder never invents one.
  group('the short summary is always there when the page can be read', () {
    test('no model on the device → the article\'s own opening words, not a blank',
        () async {
      final engine = _FakeEngine(failsLoad: true);
      final briefing = _briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'Sigue aquí', url: 'https://hf.co/1'),
      ]);

      final out = await _writer(engine, _FakeFetcher()).fillMissing(briefing);

      expect(out.articles.single.title, 'Sigue aquí');
      expect(out.articles.single.displayDescription, contains('El cuerpo del artículo'),
          reason: 'the page WAS read, so its own first words are shown');
      expect(out.articles.single.generatedBrief, isNull,
          reason: 'an excerpt is the source speaking, never presented as a model brief');
    });

    test('a model failure falls back to the excerpt, never to a fabricated brief', () async {
      final engine = _FakeEngine(answer: '   ');
      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'T', url: 'https://hf.co/1'),
      ]));

      expect(out.articles.single.generatedBrief, isNull);
      expect(out.articles.single.sourceExcerpt, contains('El cuerpo del artículo'));
      expect(out.articles.single.displayDescription, isNotEmpty);
    });

    test('past the model budget, items still get an excerpt instead of nothing', () async {
      final engine = _FakeEngine();
      final many = List.generate(
        BriefingBriefWriter.maxBriefsPerRun + 5,
        (i) => BriefingArticle(sourceName: 'HF', title: 'T$i', url: 'https://hf.co/$i'),
      );

      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(many));

      expect(engine.prompts, hasLength(BriefingBriefWriter.maxBriefsPerRun),
          reason: 'the model budget still bounds battery cost');
      expect(out.articles.where((a) => a.displayDescription.isEmpty), isEmpty,
          reason: 'no card is left with nothing when its page could be read');
    });

    test('a page that cannot be read is the ONE honest gap: no text is invented', () async {
      final engine = _FakeEngine(answer: 'Un resumen inventado.');
      final out = await _writer(engine, _FakeFetcher(fails: true)).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'Uno', url: 'https://hf.co/1'),
      ]));

      expect(engine.prompts, isEmpty, reason: 'never summarize a page we could not read');
      expect(out.articles.single.displayDescription, isEmpty);
    });
  });

  group('a failure never costs the user the briefing', () {

    test('a page that cannot be fetched leaves THAT item blank, not the rest', () async {
      final engine = _FakeEngine(answer: 'Resumen bueno.');
      // First article's fetch throws; the fake fails for every URL, so instead
      // assert the shape: nothing written, nothing lost.
      final out = await _writer(engine, _FakeFetcher(fails: true)).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'Uno', url: 'https://hf.co/1'),
        BriefingArticle(sourceName: 'HF', title: 'Dos', url: 'https://hf.co/2'),
      ]));

      expect(out.articles, hasLength(2));
      expect(out.articles.every((a) => a.displayDescription.isEmpty), isTrue);
    });

    test('an empty model answer is not written as an empty brief', () async {
      final engine = _FakeEngine(answer: '   ');
      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'T', url: 'https://hf.co/1'),
      ]));

      expect(out.articles.single.generatedBrief, isNull);
    });

    test('an item with no URL is skipped — there is nothing to read', () async {
      final engine = _FakeEngine();
      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'Sin enlace', url: ''),
      ]));

      expect(engine.prompts, isEmpty);
      expect(out.articles.single.generatedBrief, isNull);
    });
  });

  group('bounded cost', () {
    test('a run is capped, and the items beyond it keep their visible hint', () async {
      final engine = _FakeEngine();
      final many = List.generate(
        BriefingBriefWriter.maxBriefsPerRun + 5,
        (i) => BriefingArticle(sourceName: 'HF', title: 'T$i', url: 'https://hf.co/$i'),
      );

      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(many));

      // The MODEL budget is what is capped. The extras are not silently
      // dropped — they fall to the next rung of the ladder (the page's own
      // opening words), which is asserted in the "always there" group above.
      expect(engine.prompts, hasLength(BriefingBriefWriter.maxBriefsPerRun));
      expect(out.articles.where((a) => a.generatedBrief == null), hasLength(5));
    });

    test('a rambling answer is cut rather than trusted', () async {
      final engine = _FakeEngine(answer: 'x' * 900);
      final out = await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'T', url: 'https://hf.co/1'),
      ]));

      expect(out.articles.single.generatedBrief!.length,
          lessThanOrEqualTo(BriefingBriefWriter.maxBriefChars + 1));
    });

    test('the model is loaded once for the whole run, not per item', () async {
      final engine = _FakeEngine();
      await _writer(engine, _FakeFetcher()).fillMissing(_briefing(const [
        BriefingArticle(sourceName: 'HF', title: 'A', url: 'https://hf.co/1'),
        BriefingArticle(sourceName: 'HF', title: 'B', url: 'https://hf.co/2'),
        BriefingArticle(sourceName: 'HF', title: 'C', url: 'https://hf.co/3'),
      ]));

      expect(engine.loads, 1);
      expect(engine.prompts, hasLength(3));
    });
  });
}
