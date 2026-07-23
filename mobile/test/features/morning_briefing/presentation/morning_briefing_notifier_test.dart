// Proves the ON-DEVICE morning-briefing pipeline end to end with a fake fetcher
// + fake engine (no network, no real model): it loads the model on demand,
// summarizes every reachable source with the LONGSUM tuned sampling
// (0.2 / 20 / 0.9), skips a failing source without aborting, persists the
// briefing, and posts the local notification.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_notifier.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

const _rssA = '''
<rss version="2.0"><channel><title>Fuente A</title>
<item><title>Noticia A1</title><description>Detalle A1</description></item>
</channel></rss>''';

const _rssB = '''
<rss version="2.0"><channel><title>Fuente B</title>
<item><title>Noticia B1</title><description>Detalle B1</description></item>
</channel></rss>''';

ProviderContainer _container({
  required FakeLocalLlmEngine engine,
  required FakeSourceFetcher fetcher,
  required FakeMorningBriefingPreferences prefs,
  required FakeBriefingNotifications notifications,
}) {
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      sourceFetcherProvider.overrideWithValue(fetcher),
      morningBriefingPreferencesProvider.overrideWithValue(prefs),
      briefingNotificationsProvider.overrideWithValue(notifications),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('hydrates configured sources + last briefing on build', () async {
    final prefs = FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']);
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(),
      prefs: prefs,
      notifications: FakeBriefingNotifications(),
    );

    await container.read(morningBriefingNotifierProvider.notifier).ready;
    expect(container.read(morningBriefingNotifierProvider).sources, ['https://a.com/rss']);
  });

  test('generates a briefing: loads model, summarizes each source, persists, notifies', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final fetcher = FakeSourceFetcher(bodies: {
      'https://a.com/rss': _rssA,
      'https://b.com/rss': _rssB,
    });
    final prefs = FakeMorningBriefingPreferences(
      initialSources: ['https://a.com/rss', 'https://b.com/rss'],
    );
    final notifications = FakeBriefingNotifications();
    final container = _container(engine: engine, fetcher: fetcher, prefs: prefs, notifications: notifications);
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.done);
    expect(engine.loadCount, 1, reason: 'model loaded on demand');
    expect(state.briefing, isNotNull);
    expect(state.briefing!.items.length, 2);
    expect(state.briefing!.items.map((i) => i.sourceTitle), containsAll(['Fuente A', 'Fuente B']));
    expect(prefs.saveCount, 1, reason: 'briefing persisted');
    expect(notifications.shown, 1, reason: 'local notification posted');
  });

  test('uses the LONGSUM tuned sampling (0.2 / 20 / 0.9) for every summary call', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final fetcher = FakeSourceFetcher(bodies: {'https://a.com/rss': _rssA});
    final container = _container(
      engine: engine,
      fetcher: fetcher,
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']),
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    // One source summary + one intro = 2 generate calls, all with longsum.
    expect(engine.generateSampling, isNotEmpty);
    for (final sampling in engine.generateSampling) {
      expect(sampling, (0.2, 20, 0.9));
    }
  });

  test('skips a failing source without aborting the briefing', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final fetcher = FakeSourceFetcher(
      bodies: {'https://ok.com/rss': _rssA},
      failing: {'https://bad.com/rss'},
    );
    final container = _container(
      engine: engine,
      fetcher: fetcher,
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://bad.com/rss', 'https://ok.com/rss']),
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.done);
    expect(state.briefing!.items.length, 1, reason: 'only the reachable source survives');
    expect(state.briefing!.items.single.sourceTitle, 'Fuente A');
  });

  test('errors when the model fails to load', () async {
    final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
    final container = _container(
      engine: engine,
      fetcher: FakeSourceFetcher(bodies: {'https://a.com/rss': _rssA}),
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']),
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.error);
    expect(state.error, contains('No se pudo cargar el modelo'));
  });

  test('errors when there are no configured sources', () async {
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(),
      prefs: FakeMorningBriefingPreferences(initialSources: const []),
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.error);
    expect(state.error, contains('Agrega al menos una fuente'));
  });

  test('errors when every source fails to yield content', () async {
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(failing: {'https://a.com/rss'}),
      prefs: FakeMorningBriefingPreferences(initialSources: ['https://a.com/rss']),
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.generate();

    final state = container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.error);
    expect(state.error, contains('ninguna fuente'));
  });

  test('addSource + removeSource persist through the preferences', () async {
    final prefs = FakeMorningBriefingPreferences(initialSources: const []);
    final container = _container(
      engine: FakeLocalLlmEngine(installed: true),
      fetcher: FakeSourceFetcher(),
      prefs: prefs,
      notifications: FakeBriefingNotifications(),
    );
    final notifier = container.read(morningBriefingNotifierProvider.notifier);
    await notifier.ready;

    await notifier.addSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources, ['https://new.com/rss']);
    expect(await prefs.sources(), ['https://new.com/rss']);

    // De-duplicates.
    await notifier.addSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources.length, 1);

    await notifier.removeSource('https://new.com/rss');
    expect(container.read(morningBriefingNotifierProvider).sources, isEmpty);
    expect(await prefs.sources(), isEmpty);
  });
}
