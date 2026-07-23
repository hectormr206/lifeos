// Proves the REDESIGNED on-device morning-briefing pipeline: generation does
// NO bulk model summarization (fetch + parse + freshness + group only), the
// model runs ONLY on demand per item, and the on-demand full-article + HN
// comments summaries are cached back onto the article.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_notifier.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';

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

ProviderContainer _container({
  required FakeLocalLlmEngine engine,
  required FakeSourceFetcher fetcher,
  required FakeMorningBriefingPreferences prefs,
  required FakeBriefingNotifications notifications,
  required DateTime now,
}) {
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      sourceFetcherProvider.overrideWithValue(fetcher),
      morningBriefingPreferencesProvider.overrideWithValue(prefs),
      briefingNotificationsProvider.overrideWithValue(notifications),
      briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
      clockProvider.overrideWithValue(_FixedClock(now)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final now = DateTime(2026, 7, 22, 9);
  final today = DateTime(2026, 7, 22, 6);

  test('generates a grouped briefing WITHOUT loading the model or summarizing', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final fetcher = FakeSourceFetcher(bodies: {
      'https://a.com/rss': _datedRss('Fuente A', 'Noticia A1', today),
      'https://b.com/rss': _datedRss('Fuente B', 'Noticia B1', today),
      hnFrontPageUrl: _hnFrontPage(today),
    });
    final prefs = FakeMorningBriefingPreferences(
      initialSources: ['https://a.com/rss', 'https://b.com/rss'],
    );
    final notifications = FakeBriefingNotifications();
    final container = _container(
        engine: engine, fetcher: fetcher, prefs: prefs, notifications: notifications, now: now);
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.done);
    expect(engine.loadCount, 0, reason: 'generation must NOT load the model');
    expect(engine.generateCount, 0, reason: 'generation must NOT summarize');
    // Fuente A, Fuente B and Hacker News each contribute one group.
    expect(state.briefing!.groups.map((g) => g.sourceName),
        containsAll(['Fuente A', 'Fuente B', 'Hacker News']));
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
        engine: engine, fetcher: fetcher, prefs: prefs, notifications: FakeBriefingNotifications(), now: now);
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
    expect(engine.generateSampling.single, (0.2, 20, 0.9));
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
