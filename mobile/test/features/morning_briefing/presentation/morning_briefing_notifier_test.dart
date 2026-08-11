// Proves the REDESIGNED on-device morning-briefing pipeline: generation does
// NO bulk model summarization (fetch + parse + freshness + group only), the
// model runs ONLY on demand per item, and the on-demand full-article + HN
// comments summaries are cached back onto the article.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_notifier.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

/// A fixed clock so "today/yesterday" freshness is deterministic in tests.
class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

/// Builds a dated RSS body whose single item is published at [pub].
String _datedRss(String channel, String title, DateTime pub) {
  final rfc = _toRfc822(pub.toUtc());
  return '''
<rss version="2.0"><channel><title>$channel</title>
<item><title>$title</title><link>https://ex.com/${title.hashCode}</link>
<description>Detalle de $title</description><pubDate>$rfc</pubDate></item>
</channel></rss>''';
}

String _toRfc822(DateTime dt) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)} ${months[dt.month - 1]} ${dt.year} ${two(dt.hour)}:${two(dt.minute)}:00 GMT';
}

String _hnFrontPage(DateTime pub) => '''
{"hits":[{"objectID":"42","title":"HN Story","url":"https://ext.com/story","created_at":"${pub.toUtc().toIso8601String()}"}]}''';

/// Builds an RSS feed with English titles + descriptions (for the translation
/// tests: it should be detected as NON-target when the app language is es).
String _englishRss(String channel, List<(String, String)> items, DateTime pub) {
  final rfc = _toRfc822(pub.toUtc());
  final buffer = StringBuffer('<rss version="2.0"><channel><title>$channel</title>');
  for (final (title, desc) in items) {
    buffer.write('<item><title>$title</title>'
        '<link>https://en.com/${title.hashCode}</link>'
        '<description>$desc</description><pubDate>$rfc</pubDate></item>');
  }
  buffer.write('</channel></rss>');
  return buffer.toString();
}

ProviderContainer _container({
  required FakeLocalLlmEngine engine,
  required FakeSourceFetcher fetcher,
  required FakeMorningBriefingPreferences prefs,
  required FakeBriefingNotifications notifications,
  required DateTime now,
  String? languageCode,
}) {
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      sourceFetcherProvider.overrideWithValue(fetcher),
      morningBriefingPreferencesProvider.overrideWithValue(prefs),
      briefingNotificationsProvider.overrideWithValue(notifications),
      briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
      clockProvider.overrideWithValue(_FixedClock(now)),
      if (languageCode != null) appLanguageCodeProvider.overrideWithValue(languageCode),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final now = DateTime(2026, 7, 22, 9);
  final today = DateTime(2026, 7, 22, 6);

  test('groups sources and never summarizes; same-language sources need no model', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final fetcher = FakeSourceFetcher(bodies: {
      'https://a.com/rss': _datedRss('Fuente A', 'Noticia A1', today),
      'https://b.com/rss': _datedRss('Fuente B', 'Noticia B1', today),
      hnFrontPageUrl: '{"hits":[]}',
    });
    final prefs = FakeMorningBriefingPreferences(
      initialSources: ['https://a.com/rss', 'https://b.com/rss'],
    );
    final notifications = FakeBriefingNotifications();
    final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: prefs,
        notifications: notifications,
        now: now,
        languageCode: 'es');
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.done);
    // Sources already in Spanish are detected as same-language → no model work.
    expect(engine.loadCount, 0, reason: 'Spanish sources need no translation');
    expect(engine.generateCount, 0, reason: 'generation must NOT summarize');
    expect(state.briefing!.groups.map((g) => g.sourceName),
        containsAll(['Fuente A', 'Fuente B']));
    expect(prefs.saveCount, 1, reason: 'briefing persisted');
    expect(notifications.shown, 1, reason: 'local notification posted');
  });

  test('freshness: keeps today/yesterday, drops older, records skipped sources', () async {
    final fetcher = FakeSourceFetcher(bodies: {
      'https://fresh.com/rss': _datedRss('Fresca', 'Hoy', today),
      'https://stale.com/rss':
          _datedRss('Vieja', 'Antigua', DateTime(2026, 7, 1)),
      hnFrontPageUrl: '{"hits":[]}',
    });
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: fetcher,
      prefs: FakeMorningBriefingPreferences(
          initialSources: ['https://fresh.com/rss', 'https://stale.com/rss']),
      notifications: FakeBriefingNotifications(),
      now: now,
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final briefing = container.read(morningBriefingNotifierProvider).briefing!;
    expect(briefing.groups.map((g) => g.sourceName), ['Fresca']);
    expect(briefing.skippedSources, containsAll(['Vieja', 'Hacker News']));
  });

  test('caps at 10 fresh items per source', () async {
    final buffer = StringBuffer('<rss version="2.0"><channel><title>Prolija</title>');
    final rfc = _toRfc822(today.toUtc());
    for (var i = 0; i < 15; i++) {
      buffer.write(
          '<item><title>N$i</title><link>https://p.com/$i</link><pubDate>$rfc</pubDate></item>');
    }
    buffer.write('</channel></rss>');
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(
          bodies: {'https://p.com/rss': buffer.toString(), hnFrontPageUrl: '{"hits":[]}'}),
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://p.com/rss']),
      notifications: FakeBriefingNotifications(),
      now: now,
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final group = container
        .read(morningBriefingNotifierProvider)
        .briefing!
        .groups
        .firstWhere((g) => g.sourceName == 'Prolija');
    expect(group.articles.length, 10, reason: 'capped at 10 per source');
  });

  test('errors when no source yields any fresh item', () async {
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(
          bodies: {'https://s.com/rss': _datedRss('S', 'Old', DateTime(2026, 1, 1))},
          failing: {hnFrontPageUrl}),
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://s.com/rss']),
      notifications: FakeBriefingNotifications(),
      now: now,
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.error);
    expect(state.error, contains('No hay noticias frescas'));
  });

  test('on-demand full summary: loads model, uses LONGSUM sampling, caches result', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Resumen del artículo');
    final fetcher = FakeSourceFetcher(bodies: {
      'https://a.com/rss': _datedRss('Fuente A', 'Noticia A1', today),
      hnFrontPageUrl: '{"hits":[]}',
      // The article page fetched on demand.
      'https://ex.com/${'Noticia A1'.hashCode}':
          '<html><head><title>Art</title></head><body><p>Cuerpo del artículo largo.</p></body></html>',
    });
    final prefs = FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']);
    final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: prefs,
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es');
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;
    await notifier.generate();

    final article = container
        .read(morningBriefingNotifierProvider)
        .briefing!
        .groups
        .first
        .articles
        .first;
    await notifier.summarizeArticle(article);

    final updated =
        container.read(morningBriefingNotifierProvider).briefing!.articleForKey(article.key)!;
    expect(engine.loadCount, 1, reason: 'model loaded on demand');
    expect(updated.fullSummary, 'Resumen del artículo');
    expect(engine.generateSampling.single, (0.2, 20, 0.9));

    // A second request is a no-op (cached) — no extra generate call.
    await notifier.summarizeArticle(updated);
    expect(engine.generateCount, 1, reason: 'cached summary is not regenerated');
  });

  test('on-demand HN comments summary: fetches thread, summarizes, caches', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => 'Resumen de comentarios');
    final fetcher = FakeSourceFetcher(bodies: {
      hnFrontPageUrl: _hnFrontPage(today),
      '${hnItemUrlPrefix}42':
          '{"children":[{"author":"alice","text":"Gran punto"},{"author":"bob","text":"No estoy de acuerdo"}]}',
    });
    final container = _container(
      engine: engine,
      fetcher: fetcher,
      prefs: FakeMorningBriefingPreferences(initialSources: const []),
      notifications: FakeBriefingNotifications(),
      now: now,
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;
    await notifier.generate();

    final hnArticle = container
        .read(morningBriefingNotifierProvider)
        .briefing!
        .articles
        .firstWhere((a) => a.isHackerNews);
    await notifier.summarizeComments(hnArticle);

    final updated =
        container.read(morningBriefingNotifierProvider).briefing!.articleForKey(hnArticle.key)!;
    expect(updated.commentsSummary, 'Resumen de comentarios');
    // Generation eagerly translates the (English) HN headline first; the LONGSUM
    // sampling is the LAST call (the on-demand comments summary).
    expect(engine.generateSampling.last, (0.2, 20, 0.9));
  });

  group('eager per-source title translation (at generation)', () {
    test('translates EVERY source up front, caches on the article + persists', () async {
      // Fake engine returns the batched numbered translation for the 2 titles.
      final engine = FakeLocalLlmEngine(
        installed: true,
        reply: (_) => '1. El futuro de la IA ||| Un vistazo al futuro\n'
            '2. Nuevo lanzamiento de Rust ||| Notas de la versión',
      );
      final fetcher = FakeSourceFetcher(bodies: {
        'https://en.com/rss': _englishRss(
          'English Source',
          [
            ('The Future of AI', 'A look at the future'),
            ('New Rust Release', 'Release notes'),
          ],
          today,
        ),
        hnFrontPageUrl: '{"hits":[]}',
      });
      final prefs = FakeMorningBriefingPreferences(initialSources: ['https://en.com/rss']);
      final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: prefs,
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;

      // No expand needed: generation translates all sources.
      await notifier.generate();

      final group = container
          .read(morningBriefingNotifierProvider)
          .briefing!
          .groups
          .firstWhere((g) => g.sourceName == 'English Source');
      expect(engine.loadCount, 1, reason: 'model loaded once for translation');
      expect(engine.generateCount, 1, reason: 'ONE batched call for the whole source');
      expect(engine.generateSampling.single, (0.3, 20, 0.9), reason: 'light translation sampling');
      expect(group.articles[0].displayTitle, 'El futuro de la IA');
      expect(group.articles[0].translatedTitle, 'El futuro de la IA');
      expect(group.articles[0].displayDescription, 'Un vistazo al futuro');
      expect(group.articles[1].displayTitle, 'Nuevo lanzamiento de Rust');

      // Persisted WITH the translation cached (survives reload).
      expect(prefs.saveCount, 1);
      final reloaded = await prefs.lastBriefing();
      expect(reloaded!.articles.first.translatedTitle, 'El futuro de la IA');
    });

    test('a REPEATED source name (non-adjacent runs) is translated ONCE', () async {
      // Regression: _translateAll iterated assembled.groups (consecutive
      // same-source runs only), so a source title appearing in two
      // NON-ADJACENT runs (feed + atom of the same site) triggered a second
      // FULL model call over the exact same articles.
      final engine = FakeLocalLlmEngine(
        installed: true,
        reply: (_) => '1. Título traducido ||| Resumen traducido\n'
            '2. Otro título ||| Otro resumen',
      );
      final fetcher = FakeSourceFetcher(bodies: {
        // Two DIFFERENT URLs whose channel <title> is identical…
        'https://same.com/rss': _englishRss(
          'Same Blog',
          [('The Future of AI', 'A look ahead')],
          today,
        ),
        'https://same.com/atom': _englishRss(
          'Same Blog',
          [('New Rust Release', 'Release notes')],
          today,
        ),
        // …separated by a Spanish source so the runs are NOT adjacent.
        'https://es.com/rss':
            _datedRss('Fuente Española', 'La economía de España crece hoy', today),
        hnFrontPageUrl: '{"hits":[]}',
      });
      final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: FakeMorningBriefingPreferences(initialSources: [
          'https://same.com/rss',
          'https://es.com/rss',
          'https://same.com/atom',
        ]),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      expect(engine.generateCount, 1,
          reason: 'ONE batched call covers every "Same Blog" article — never a '
              'duplicate full model pass over the same items');
    });

    test('skips a source already in the target language (no model call)', () async {
      final engine = FakeLocalLlmEngine(installed: true);
      final fetcher = FakeSourceFetcher(bodies: {
        'https://es.com/rss': _datedRss('Fuente Española', 'La economía de España crece hoy', today),
        hnFrontPageUrl: '{"hits":[]}',
      });
      final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: FakeMorningBriefingPreferences(initialSources: ['https://es.com/rss']),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      expect(engine.loadCount, 0, reason: 'same-language source is NOT translated');
      expect(engine.generateCount, 0);
      final group = container
          .read(morningBriefingNotifierProvider)
          .briefing!
          .groups
          .firstWhere((g) => g.sourceName == 'Fuente Española');
      expect(group.articles.first.displayTitle, 'La economía de España crece hoy');
    });

    test('per-source failure keeps that source native; the rest still translate', () async {
      // The engine THROWS for the source whose prompt mentions "Explode" and
      // succeeds for the other — proving per-source failure isolation.
      final engine = FakeLocalLlmEngine(
        installed: true,
        reply: (p) =>
            p.contains('Explode') ? throw Exception('boom') : '1. El futuro de la IA',
      );
      final fetcher = FakeSourceFetcher(bodies: {
        'https://x.com/rss': _englishRss('Broken Source', [('Explode Now', 'boom desc')], today),
        'https://y.com/rss': _englishRss('Good Source', [('The Future of AI', 'A look')], today),
        hnFrontPageUrl: '{"hits":[]}',
      });
      final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: FakeMorningBriefingPreferences(
            initialSources: ['https://x.com/rss', 'https://y.com/rss']),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      final state = container.read(morningBriefingNotifierProvider);
      expect(state.phase, BriefingPhase.done, reason: 'briefing still completes');
      final broken = state.briefing!.groups.firstWhere((g) => g.sourceName == 'Broken Source');
      final good = state.briefing!.groups.firstWhere((g) => g.sourceName == 'Good Source');
      expect(broken.articles.first.translatedTitle, isNull);
      expect(broken.articles.first.displayTitle, 'Explode Now', reason: 'native fallback, never blank');
      expect(good.articles.first.displayTitle, 'El futuro de la IA', reason: 'the rest still translate');
    });

    test('cleans raw/escaped HTML out of a description BEFORE translation', () async {
      // A messy feed (like Simon Willison\'s) that ships escaped HTML in
      // <description>. The text reaching the model must be plain — no tags —
      // otherwise the source stays untranslated (the reported bug).
      final engine = FakeLocalLlmEngine(installed: true, reply: (_) => '1. Titular traducido');
      final messyRss = '<rss version="2.0"><channel><title>Messy Source</title>'
          '<item><title>The Future of AI</title>'
          '<link>https://messy.com/1</link>'
          '<description>&lt;p&gt;Hello &lt;b&gt;world&lt;/b&gt;&lt;/p&gt;</description>'
          '<pubDate>${_toRfc822(today.toUtc())}</pubDate></item></channel></rss>';
      final container = _container(
        engine: engine,
        fetcher: FakeSourceFetcher(
            bodies: {'https://messy.com/rss': messyRss, hnFrontPageUrl: '{"hits":[]}'}),
        prefs: FakeMorningBriefingPreferences(initialSources: ['https://messy.com/rss']),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      expect(engine.prompts, isNotEmpty, reason: 'the messy source WAS translated');
      final prompt = engine.prompts.single;
      expect(prompt, contains('Hello world'), reason: 'description cleaned to plain text');
      expect(prompt, isNot(contains('<')), reason: 'no raw tags reach the model');
      expect(prompt, isNot(contains('&lt;')), reason: 'no escaped tags reach the model');
    });
  });

  group('on-demand summaries queue instead of racing', () {
    /// Two Spanish sources (no translation model calls to muddy the counts),
    /// each with one article whose page can be fetched on demand.
    ProviderContainer twoArticleContainer(FakeLocalLlmEngine engine) {
      final page = '<html><head><title>Art</title></head>'
          '<body><p>Cuerpo del artículo largo y legible.</p></body></html>';
      final fetcher = FakeSourceFetcher(bodies: {
        'https://a.com/rss': _datedRss('Fuente A', 'Noticia A1', today),
        'https://b.com/rss': _datedRss('Fuente B', 'Noticia B1', today),
        hnFrontPageUrl: '{"hits":[]}',
        'https://ex.com/${'Noticia A1'.hashCode}': page,
        'https://ex.com/${'Noticia B1'.hashCode}': page,
      });
      return _container(
        engine: engine,
        fetcher: fetcher,
        prefs: FakeMorningBriefingPreferences(
          initialSources: ['https://a.com/rss', 'https://b.com/rss'],
        ),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
    }

    test('a second tap WAITS in the queue; both summaries complete', () async {
      // The reported bug: tapping a second "ver resumen completo" while the
      // first is still running cut the first one short ("se queda mocho").
      final gate = Completer<void>();
      final engine = FakeLocalLlmEngine(
        installed: true,
        generateGate: gate,
        reply: (p) => 'Resumen de ${p.contains('A1') ? 'A1' : 'B1'}',
      );
      final container = twoArticleContainer(engine);
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      final articles = container.read(morningBriefingNotifierProvider).briefing!.articles;
      final first = articles.firstWhere((a) => a.title == 'Noticia A1');
      final second = articles.firstWhere((a) => a.title == 'Noticia B1');

      final f1 = notifier.summarizeArticle(first);
      final f2 = notifier.summarizeArticle(second);
      await pumpEventQueue();

      var state = container.read(morningBriefingNotifierProvider);
      expect(state.isSummarizingArticle(first.key), isTrue, reason: 'the first is running');
      expect(state.isQueuedArticle(second.key), isTrue,
          reason: 'the second is visibly waiting its turn, not running');
      expect(state.isSummarizingArticle(second.key), isFalse);
      expect(engine.generateCount, 1, reason: 'never two generations at once');

      gate.complete();
      await Future.wait([f1, f2]);

      state = container.read(morningBriefingNotifierProvider);
      expect(state.briefing!.articleForKey(first.key)!.fullSummary, 'Resumen de A1');
      expect(state.briefing!.articleForKey(second.key)!.fullSummary, 'Resumen de B1',
          reason: 'the queued request is served, never dropped');
      expect(state.isQueuedArticle(second.key), isFalse);
      expect(state.isSummarizingArticle(second.key), isFalse);
    });

    test('a queued comments summary is reported as waiting, then runs', () async {
      final gate = Completer<void>();
      final engine = FakeLocalLlmEngine(
        installed: true,
        generateGate: gate,
        reply: (_) => 'Resumen',
      );
      final fetcher = FakeSourceFetcher(bodies: {
        'https://a.com/rss': _datedRss('Fuente A', 'Noticia A1', today),
        // A Spanish HN headline: generation must not spend a (gated) model call
        // on translation, so the gate only ever holds the on-demand summaries.
        hnFrontPageUrl: '{"hits":[{"objectID":"42",'
            '"title":"La economía de España crece hoy",'
            '"url":"https://ext.com/story",'
            '"created_at":"${today.toUtc().toIso8601String()}"}]}',
        'https://ex.com/${'Noticia A1'.hashCode}':
            '<html><body><p>Cuerpo del artículo largo.</p></body></html>',
        // ext.com is deliberately NOT fetchable: the brief writer must not
        // spend the (gated) model on it before the on-demand summaries run.
        '${hnItemUrlPrefix}42': '{"children":[{"author":"alice","text":"Gran punto"}]}',
      });
      final container = _container(
        engine: engine,
        fetcher: fetcher,
        prefs: FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']),
        notifications: FakeBriefingNotifications(),
        now: now,
        languageCode: 'es',
      );
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      final state0 = container.read(morningBriefingNotifierProvider);
      final article = state0.briefing!.articles.firstWhere((a) => a.title == 'Noticia A1');
      final hn = state0.briefing!.articles.firstWhere((a) => a.isHackerNews);

      final f1 = notifier.summarizeArticle(article);
      final f2 = notifier.summarizeComments(hn);
      await pumpEventQueue();

      var state = container.read(morningBriefingNotifierProvider);
      expect(state.isSummarizingArticle(article.key), isTrue);
      expect(state.isQueuedComments(hn.key), isTrue,
          reason: 'the comments summary shares the model, so it waits too');
      expect(state.isSummarizingComments(hn.key), isFalse);

      gate.complete();
      await Future.wait([f1, f2]);

      state = container.read(morningBriefingNotifierProvider);
      expect(state.briefing!.articleForKey(hn.key)!.commentsSummary, 'Resumen');
      expect(state.isQueuedComments(hn.key), isFalse);
    });

    test('a re-tap while queued does not enqueue the same article twice', () async {
      final gate = Completer<void>();
      final engine = FakeLocalLlmEngine(
        installed: true,
        generateGate: gate,
        reply: (_) => 'Resumen',
      );
      final container = twoArticleContainer(engine);
      final notifier = container.read(morningBriefingNotifierProvider.notifier);
      await notifier.ready;
      await notifier.generate();

      final articles = container.read(morningBriefingNotifierProvider).briefing!.articles;
      final first = articles.firstWhere((a) => a.title == 'Noticia A1');
      final second = articles.firstWhere((a) => a.title == 'Noticia B1');

      final futures = [
        notifier.summarizeArticle(first),
        notifier.summarizeArticle(second),
        notifier.summarizeArticle(second),
      ];
      await pumpEventQueue();
      gate.complete();
      await Future.wait(futures);

      expect(engine.generateCount, 2, reason: 'the duplicate tap was ignored, not re-queued');
    });
  });

  test('addSource + removeSource persist through the preferences', () async {
    final prefs = FakeMorningBriefingPreferences(initialSources: const []);
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(),
      prefs: prefs,
      notifications: FakeBriefingNotifications(),
      now: now,
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.addSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources, ['https://new.com/rss']);
    await notifier.addSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources.length, 1);
    await notifier.removeSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources, isEmpty);
  });
}
