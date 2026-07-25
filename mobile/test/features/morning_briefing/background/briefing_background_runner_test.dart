// Proves the headless WorkManager task body ("Segundo plano") with fakes:
// the already-generated-today guard skips (that is also the double-generation
// lock against the in-app path), a missing model file keeps the ORIGINAL text
// (never a download), a present model translates, a total fetch failure skips
// cleanly without crashing, the "listo" notification posts on success, the
// fired "toca aquí" reminder is removed, and the next-day chain (reminder +
// one-off work) is re-armed after EVERY outcome. No plugins, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/morning_briefing/background/briefing_background_runner.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_assembler.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_harvester.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

/// A DATED RSS body published "now" so the freshness filter keeps it.
String _dated(DateTime now) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final dt = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final rfc = '${two(dt.day)} ${months[dt.month - 1]} ${dt.year} ${two(dt.hour)}:${two(dt.minute)}:00 GMT';
  return '''
<rss version="2.0"><channel><title>Fuente A</title>
<item><title>The AI Future</title><link>https://a.com/1</link><description>A look at what is new in the AI world</description><pubDate>$rfc</pubDate></item>
</channel></rss>''';
}

({
  BriefingBackgroundDeps deps,
  FakeMorningBriefingPreferences prefs,
  FakeSourceFetcher fetcher,
  FakeBriefingNotifications notifications,
  FakeBriefingScheduler reminder,
  FakeBriefingBackgroundWork work,
  FakeLocalLlmEngine engine,
}) _harness({
  required DateTime now,
  BriefingSchedule? schedule,
  OnDeviceBriefing? lastBriefing,
  bool modelAvailable = false,
  LocalLlmEngine? engineOverride,
  FakeSourceFetcher? fetcherOverride,
  Duration timeout = const Duration(seconds: 5),
  String Function(String prompt)? reply,
}) {
  final engine = FakeLocalLlmEngine(installed: modelAvailable, reply: reply);
  final prefs = FakeMorningBriefingPreferences(
    initialSources: ['https://a.com/rss'],
    initialBriefing: lastBriefing,
    initialSchedule: schedule ?? const BriefingSchedule(enabled: true),
  );
  final fetcher = fetcherOverride ??
      FakeSourceFetcher(bodies: {
        'https://a.com/rss': _dated(now),
        hnFrontPageUrl: '{"hits":[]}',
      });
  final notifications = FakeBriefingNotifications();
  final reminder = FakeBriefingScheduler();
  final work = FakeBriefingBackgroundWork();
  final deps = BriefingBackgroundDeps(
    preferences: prefs,
    harvester: BriefingHarvester(fetcher: fetcher, extractor: const SourceContentExtractor()),
    assembler: const BriefingAssembler(),
    isModelAvailable: () async => modelAvailable,
    engine: engineOverride ?? engine,
    notifications: notifications,
    reminderScheduler: reminder,
    backgroundWork: work,
    now: () => now,
    overrideLocation: () async => null,
    languageCode: () async => 'es',
    timeout: timeout,
  );
  return (
    deps: deps,
    prefs: prefs,
    fetcher: fetcher,
    notifications: notifications,
    reminder: reminder,
    work: work,
    engine: engine,
  );
}

void main() {
  final atSlot = DateTime(2026, 7, 22, 8, 5); // past the 8:00 default slot

  test('already generated today → skips generation, still re-arms tomorrow', () async {
    final existing = OnDeviceBriefing(
      articles: const [BriefingArticle(sourceName: 'F', title: 'T', url: 'https://a.com')],
      generatedAt: DateTime(2026, 7, 22, 7, 55), // the in-app path ran first
    );
    final h = _harness(now: atSlot, lastBriefing: existing);

    final ok = await runMorningBriefingBackgroundTask(h.deps);

    expect(ok, isTrue);
    expect(h.fetcher.fetched, isEmpty, reason: 'guard fires BEFORE any network work');
    expect(h.prefs.saveCount, 0);
    expect(h.notifications.shown, 0);
    expect(h.reminder.lastScheduled, DateTime(2026, 7, 23, 8, 0));
    expect(h.work.lastDelay, DateTime(2026, 7, 23, 8, 0).difference(atSlot),
        reason: 'next one-off armed for tomorrow — the chain is self-perpetuating');
  });

  test('model file ABSENT → persists the briefing with ORIGINAL text, no model call', () async {
    final h = _harness(now: atSlot, modelAvailable: false);

    await runMorningBriefingBackgroundTask(h.deps);

    expect(h.prefs.saveCount, 1);
    final saved = await h.prefs.lastBriefing();
    expect(saved!.articles.first.title, 'The AI Future');
    expect(saved.articles.first.translatedTitle, isNull, reason: 'originals kept');
    expect(h.engine.loadCount, 0, reason: 'NEVER loads (or downloads) the model when absent');
    expect(h.notifications.shown, 1, reason: '"listo" posted so the tap opens the briefing');
    expect(h.reminder.cancelCount, greaterThan(0),
        reason: 'the redundant "toca aquí" reminder is removed');
  });

  test('model file PRESENT → translates via the on-device engine, then persists', () async {
    final h = _harness(
      now: atSlot,
      modelAvailable: true,
      reply: (_) => '1. El futuro de la IA ||| Un vistazo a lo nuevo del mundo de la IA',
    );

    await runMorningBriefingBackgroundTask(h.deps);

    final saved = await h.prefs.lastBriefing();
    expect(saved!.articles.first.translatedTitle, 'El futuro de la IA');
    expect(saved.articles.first.translatedDescription, 'Un vistazo a lo nuevo del mundo de la IA');
    expect(h.engine.loadCount, greaterThan(0));
    expect(h.notifications.shown, 1);
  });

  test('translation failure keeps the originals — the fetched news is never lost', () async {
    final h = _harness(
      now: atSlot,
      modelAvailable: true,
      engineOverride: FakeLocalLlmEngine(installed: true, loadShouldFail: true),
    );

    await runMorningBriefingBackgroundTask(h.deps);

    final saved = await h.prefs.lastBriefing();
    expect(saved, isNotNull);
    expect(saved!.articles.first.title, 'The AI Future');
    expect(saved.articles.first.translatedTitle, isNull);
    expect(h.notifications.shown, 1);
  });

  test('every fetch fails (no network) → clean skip: nothing persisted, no crash, re-armed', () async {
    final h = _harness(
      now: atSlot,
      fetcherOverride: FakeSourceFetcher(failing: {'https://a.com/rss', hnFrontPageUrl}),
    );

    final ok = await runMorningBriefingBackgroundTask(h.deps);

    expect(ok, isTrue, reason: 'WorkManager must never retry-loop a failed generation');
    expect(h.prefs.saveCount, 0, reason: 'an empty briefing is not persisted');
    expect(h.notifications.shown, 0);
    expect(h.reminder.lastScheduled, DateTime(2026, 7, 23, 8, 0),
        reason: 'chain re-armed even after a bad day');
    expect(h.work.scheduledDelays, isNotEmpty);
  });

  test('schedule DISABLED → cancels both the pending work and the reminder', () async {
    final h = _harness(now: atSlot, schedule: const BriefingSchedule(enabled: false));

    await runMorningBriefingBackgroundTask(h.deps);

    expect(h.work.cancelCount, greaterThan(0));
    expect(h.reminder.cancelCount, greaterThan(0));
    expect(h.prefs.saveCount, 0);
    expect(h.work.scheduledDelays, isEmpty);
  });

  test('fired BEFORE the slot → skips (shouldRunNow) and re-arms for today\'s slot', () async {
    final early = DateTime(2026, 7, 22, 7, 30);
    final h = _harness(now: early);

    await runMorningBriefingBackgroundTask(h.deps);

    expect(h.prefs.saveCount, 0);
    expect(h.reminder.lastScheduled, DateTime(2026, 7, 22, 8, 0));
    expect(h.work.lastDelay, const Duration(minutes: 30));
  });

  test('a HUNG run hits the hard timeout and still completes cleanly', () async {
    final h = _harness(
      now: atSlot,
      fetcherOverride: _HangingFetcher(),
      timeout: const Duration(milliseconds: 50),
    );

    final ok = await runMorningBriefingBackgroundTask(h.deps);

    expect(ok, isTrue, reason: 'timeout degrades to a clean skip, never a crash-loop');
    expect(h.prefs.saveCount, 0);
    expect(h.work.scheduledDelays, isNotEmpty, reason: 'safety re-arm after the timeout');
  });
}

/// A fetcher that never completes — simulates a hung network/model pipeline so
/// the hard overall timeout is provable.
class _HangingFetcher extends FakeSourceFetcher {
  @override
  Future<String> fetch(String url) => Future<String>.delayed(const Duration(days: 1), () => '');
}
