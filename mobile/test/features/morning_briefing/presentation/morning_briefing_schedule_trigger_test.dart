// Proves the "Boletín automático" (Phase 2) trigger wiring with fakes: the
// schedule setting persists and (re)arms the OS reminder at the right instant,
// disabling cancels it, and maybeAutoGenerate — the single entry point for
// launch/resume/tap/timer — runs the pipeline only when a run is DUE (enabled,
// past the hour, and NOT already generated today), always re-arming for the
// next occurrence. Frozen clock, no alarms, no platform channels.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_notifier.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

/// A DATED RSS body published "now" so the freshness filter keeps it.
String _dated(DateTime now) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final dt = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final rfc = '${two(dt.day)} ${months[dt.month - 1]} ${dt.year} ${two(dt.hour)}:${two(dt.minute)}:00 GMT';
  return '''
<rss version="2.0"><channel><title>Fuente A</title>
<item><title>Noticia A1</title><link>https://a.com/1</link><description>Detalle A1</description><pubDate>$rfc</pubDate></item>
</channel></rss>''';
}

/// A container with every dependency faked, plus a frozen clock on the
/// notifier (set BEFORE hydration finishes so even the hydrate-time arming
/// sees the frozen "now").
({
  ProviderContainer container,
  MorningBriefingNotifier notifier,
  FakeBriefingScheduler scheduler,
  FakeMorningBriefingPreferences prefs,
  FakeBriefingNotifications notifications,
  FakeLocalLlmEngine engine,
}) _harness({
  required DateTime now,
  BriefingSchedule? initialSchedule,
  OnDeviceBriefing? initialBriefing,
  List<String>? sources,
}) {
  final engine = FakeLocalLlmEngine(installed: true);
  final scheduler = FakeBriefingScheduler();
  final notifications = FakeBriefingNotifications();
  final prefs = FakeMorningBriefingPreferences(
    initialSources: sources ?? ['https://a.com/rss'],
    initialBriefing: initialBriefing,
    initialSchedule: initialSchedule,
  );
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      sourceFetcherProvider.overrideWithValue(FakeSourceFetcher(bodies: {'https://a.com/rss': _dated(now)})),
      morningBriefingPreferencesProvider.overrideWithValue(prefs),
      briefingNotificationsProvider.overrideWithValue(notifications),
      briefingSchedulerProvider.overrideWithValue(scheduler),
      clockProvider.overrideWithValue(_FixedClock(now)),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(morningBriefingNotifierProvider.notifier)..clock = () => now;
  return (
    container: container,
    notifier: notifier,
    scheduler: scheduler,
    prefs: prefs,
    notifications: notifications,
    engine: engine,
  );
}

void main() {
  final morning = DateTime(2026, 7, 22, 6, 0); // before the 8:00 default slot

  test('enabling the schedule persists it and arms the OS reminder at the next slot', () async {
    final h = _harness(now: morning);
    await h.notifier.ready;

    await h.notifier.setScheduleEnabled(true);

    expect(h.container.read(morningBriefingNotifierProvider).schedule.enabled, isTrue);
    expect(h.prefs.saveScheduleCount, 1);
    expect(await h.prefs.schedule(), const BriefingSchedule(enabled: true, hour: 8, minute: 0));
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 22, 8, 0),
        reason: 'reminder armed for today 8:00 (still ahead of 6:00)');
  });

  test('changing the hour persists and re-arms the reminder', () async {
    final h = _harness(now: morning, initialSchedule: const BriefingSchedule(enabled: true));
    await h.notifier.ready;

    await h.notifier.setScheduleTime(9, 15);

    expect(await h.prefs.schedule(), const BriefingSchedule(enabled: true, hour: 9, minute: 15));
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 22, 9, 15));
  });

  test('disabling cancels the OS reminder and stops scheduling', () async {
    final h = _harness(now: morning, initialSchedule: const BriefingSchedule(enabled: true));
    await h.notifier.ready;
    final armedBefore = h.scheduler.scheduled.length;

    await h.notifier.setScheduleEnabled(false);

    expect(h.scheduler.cancelCount, greaterThan(0));
    expect(h.scheduler.scheduled.length, armedBefore, reason: 'no new reminder after disabling');
    expect((await h.prefs.schedule()).enabled, isFalse);
  });

  test('hydration arms the reminder from the persisted schedule', () async {
    final h = _harness(now: morning, initialSchedule: const BriefingSchedule(enabled: true));
    await h.notifier.ready;

    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 22, 8, 0));
  });

  test('maybeAutoGenerate runs the pipeline when due and re-arms for tomorrow', () async {
    final h = _harness(
      now: DateTime(2026, 7, 22, 8, 5), // past the slot, nothing generated today
      initialSchedule: const BriefingSchedule(enabled: true),
    );
    await h.notifier.ready;

    await h.notifier.maybeAutoGenerate();

    final state = h.container.read(morningBriefingNotifierProvider);
    expect(state.phase, BriefingPhase.done);
    expect(state.briefing, isNotNull, reason: 'the scheduled run generated today\'s briefing');
    expect(h.notifications.shown, 1, reason: '"listo" notification posted as in Phase 1');
    expect(h.scheduler.cancelCount, greaterThan(0),
        reason: 'the pending "toca aquí" reminder is removed once we generate');
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 23, 8, 0),
        reason: 're-armed for tomorrow after generating');
  });

  test('maybeAutoGenerate does NOT regenerate when today\'s briefing already exists', () async {
    final existing = OnDeviceBriefing(
      articles: const [BriefingArticle(sourceName: 'F', title: 'T', url: 'https://a.com')],
      generatedAt: DateTime(2026, 7, 22, 8, 1),
    );
    final h = _harness(
      now: DateTime(2026, 7, 22, 9, 0),
      initialSchedule: const BriefingSchedule(enabled: true),
      initialBriefing: existing,
    );
    await h.notifier.ready;

    await h.notifier.maybeAutoGenerate();

    final state = h.container.read(morningBriefingNotifierProvider);
    expect(state.briefing!.generatedAt, DateTime(2026, 7, 22, 8, 1),
        reason: 'existing briefing untouched');
    expect(h.notifications.shown, 0, reason: 'pipeline never ran (guard)');
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 23, 8, 0),
        reason: 'still re-armed for tomorrow');
  });

  test('maybeAutoGenerate is a no-op run-wise when the schedule is disabled', () async {
    final h = _harness(
      now: DateTime(2026, 7, 22, 9, 0),
      initialSchedule: const BriefingSchedule(enabled: false), // explicitly disabled
    );
    await h.notifier.ready;

    await h.notifier.maybeAutoGenerate();

    expect(h.engine.loadCount, 0);
    expect(h.container.read(morningBriefingNotifierProvider).briefing, isNull);
    expect(h.scheduler.scheduled, isEmpty, reason: 'nothing armed while disabled');
  });

  test('a manual run before the slot moves today\'s reminder to tomorrow', () async {
    final h = _harness(
      now: DateTime(2026, 7, 22, 7, 50),
      initialSchedule: const BriefingSchedule(enabled: true),
    );
    await h.notifier.ready;
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 22, 8, 0));

    await h.notifier.generate(); // manual FAB run at 7:50

    expect(h.container.read(morningBriefingNotifierProvider).phase, BriefingPhase.done);
    expect(h.scheduler.lastScheduled, DateTime(2026, 7, 23, 8, 0),
        reason: 'the 8:00 reminder would nag for an already-generated briefing');
  });
}
