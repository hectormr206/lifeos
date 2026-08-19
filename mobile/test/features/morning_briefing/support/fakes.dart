import 'package:lifeos/features/morning_briefing/domain/briefing_background_work.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_notifications.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_scheduler.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';

/// In-memory [SourceFetcher]: returns a canned body per URL, or throws for URLs
/// listed in [failing] so the per-source skip path is testable. No network.
class FakeSourceFetcher implements SourceFetcher {
  FakeSourceFetcher({Map<String, String>? bodies, Set<String>? failing})
      : bodies = bodies ?? const {},
        failing = failing ?? const {};

  final Map<String, String> bodies;
  final Set<String> failing;
  final List<String> fetched = [];

  @override
  Future<String> fetch(String url) async {
    fetched.add(url);
    if (failing.contains(url)) throw Exception('boom $url');
    final body = bodies[url];
    if (body == null) throw Exception('no body for $url');
    return body;
  }
}

/// In-memory [BriefingNotifications]: counts posts + stores the tap handler. No
/// flutter_local_notifications channel.
class FakeBriefingNotifications implements BriefingNotifications {
  int shown = 0;
  void Function()? handler;
  bool launched = false;

  @override
  Future<void> showBriefingReady() async => shown++;

  @override
  Future<void> registerTapHandler(void Function() onTapBriefing) async => handler = onTapBriefing;

  @override
  Future<bool> launchedByTap() async => launched;
}

/// In-memory [BriefingScheduler]: records scheduled/cancelled reminders + the
/// tap handler. No flutter_local_notifications channel, no alarms.
class FakeBriefingScheduler implements BriefingScheduler {
  final List<DateTime> scheduled = [];
  int cancelCount = 0;
  void Function()? handler;
  bool launched = false;

  /// The most recently scheduled reminder instant, or null.
  DateTime? get lastScheduled => scheduled.isEmpty ? null : scheduled.last;

  @override
  Future<void> scheduleReminder(DateTime when) async => scheduled.add(when);

  @override
  Future<void> cancelReminder() async => cancelCount++;

  @override
  Future<void> registerTapHandler(void Function() onTap) async => handler = onTap;

  @override
  Future<bool> launchedByTap() async => launched;
}

/// In-memory [BriefingBackgroundWork]: records scheduled one-off delays and
/// cancellations. No workmanager plugin channel.
class FakeBriefingBackgroundWork implements BriefingBackgroundWork {
  final List<Duration> scheduledDelays = [];
  int cancelCount = 0;

  /// The most recently scheduled delay, or null.
  Duration? get lastDelay => scheduledDelays.isEmpty ? null : scheduledDelays.last;

  @override
  Future<void> scheduleOneOff(Duration initialDelay) async => scheduledDelays.add(initialDelay);

  @override
  Future<void> cancel() async => cancelCount++;
}

/// In-memory [MorningBriefingPreferences]: no shared_preferences channel.
class FakeMorningBriefingPreferences implements MorningBriefingPreferences {
  FakeMorningBriefingPreferences({
    List<String>? initialSources,
    OnDeviceBriefing? initialBriefing,
    BriefingSchedule? initialSchedule,
  })  : // Still written as bare URLs by the suites that predate sections:
        // those tests are about scheduling and harvesting, and should not have
        // to learn a new shape to keep testing what they test.
        _sources = [
          for (final url in initialSources ?? const <String>[])
            BriefingSource(url: url, section: kDefaultBriefingSection),
        ],
        _lastBriefing = initialBriefing,
        _schedule = initialSchedule ?? const BriefingSchedule();

  List<BriefingSource> _sources;
  OnDeviceBriefing? _lastBriefing;
  BriefingSchedule _schedule;
  int saveCount = 0;
  int setSourcesCount = 0;
  int saveScheduleCount = 0;

  @override
  Future<List<BriefingSource>> sources() async =>
      List<BriefingSource>.from(_sources);

  @override
  Future<void> setSources(List<BriefingSource> sources) async {
    _sources = List<BriefingSource>.from(sources);
    setSourcesCount++;
  }

  @override
  Future<OnDeviceBriefing?> lastBriefing() async => _lastBriefing;

  @override
  Future<void> saveLastBriefing(OnDeviceBriefing briefing) async {
    _lastBriefing = briefing;
    saveCount++;
  }

  @override
  Future<BriefingSchedule> schedule() async => _schedule;

  @override
  Future<void> saveSchedule(BriefingSchedule schedule) async {
    _schedule = schedule;
    saveScheduleCount++;
  }
}
