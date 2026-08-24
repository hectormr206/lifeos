import 'package:shared_preferences/shared_preferences.dart';

import 'briefing_schedule.dart';
import 'briefing_source.dart';
import 'morning_briefing.dart';

/// Local-only persistence for the ON-DEVICE morning briefing: the user's list
/// of news-source URLs plus the last briefing the model produced (so it
/// survives navigation + relaunch).
///
/// Same rationale/shape as [AppUpdatePreferences] / [LocalModelPreferences]:
/// deliberately `shared_preferences` (non-secret UI state, must survive with no
/// engine/pairing) and abstract so notifiers depend on the interface and tests
/// inject a fake without the platform channel.
abstract class MorningBriefingPreferences {
  /// The configured news-source URLs (seeded with [defaultBriefingSources] the
  /// first time, before the user has customized anything).
  Future<List<BriefingSource>> sources();

  Future<void> setSources(List<BriefingSource> sources);

  /// The last briefing the on-device pipeline produced, or null if never run.
  Future<OnDeviceBriefing?> lastBriefing();

  Future<void> saveLastBriefing(OnDeviceBriefing briefing);

  /// The "Boletín automático" schedule (ENABLED + 8:00 by default — the
  /// "everything-on" default; the user opts out).
  Future<BriefingSchedule> schedule();

  Future<void> saveSchedule(BriefingSchedule schedule);
}

/// [MorningBriefingPreferences] backed by `shared_preferences`.
class SharedPrefsMorningBriefingPreferences
    implements MorningBriefingPreferences {
  SharedPrefsMorningBriefingPreferences({SharedPreferences? prefs})
    : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String sourcesKey = 'morning_briefing_sources';
  static const String lastBriefingKey = 'morning_briefing_last';
  static const String scheduleEnabledKey = 'morning_briefing_schedule_enabled';
  static const String scheduleHourKey = 'morning_briefing_schedule_hour';
  static const String scheduleMinuteKey = 'morning_briefing_schedule_minute';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<List<BriefingSource>> sources() async {
    final p = await _instance;
    // Absent key (first run) → seed with defaults; an empty list the user
    // deliberately saved is honored as empty.
    final stored = p.getStringList(sourcesKey);
    // Lines saved before sections existed are bare URLs; `decode` reads them
    // as "General" rather than dropping a list the user curated by hand.
    if (stored == null)
      return List<BriefingSource>.from(defaultBriefingSources);
    // Dedupe on the way out, not only on the way in: a list that already
    // holds the same feed twice (pasted by hand, or filed under two sections)
    // would otherwise keep showing two identical groups forever.
    // Heal on the way out: a feed that died after we shipped it lives on in
    // every device's stored list, where editing the defaults never reaches it.
    return healBriefingSources(
      dedupeBriefingSources([
        for (final line in stored) BriefingSource.decode(line),
      ]),
    );
  }

  @override
  Future<void> setSources(List<BriefingSource> sources) async =>
      (await _instance).setStringList(sourcesKey, [
        for (final s in dedupeBriefingSources(sources)) s.encode(),
      ]);

  @override
  Future<OnDeviceBriefing?> lastBriefing() async {
    final raw = (await _instance).getString(lastBriefingKey);
    if (raw == null) return null;
    return OnDeviceBriefing.decode(raw);
  }

  @override
  Future<void> saveLastBriefing(OnDeviceBriefing briefing) async =>
      (await _instance).setString(lastBriefingKey, briefing.encode());

  @override
  Future<BriefingSchedule> schedule() async {
    final p = await _instance;
    return BriefingSchedule(
      // Absent key (first run) → DEFAULT ON (everything-on rule); the user opts
      // out, so a never-set schedule is enabled at the default hour.
      enabled: p.getBool(scheduleEnabledKey) ?? true,
      hour: p.getInt(scheduleHourKey) ?? BriefingSchedule.defaultHour,
      minute: p.getInt(scheduleMinuteKey) ?? BriefingSchedule.defaultMinute,
    );
  }

  @override
  Future<void> saveSchedule(BriefingSchedule schedule) async {
    final p = await _instance;
    await p.setBool(scheduleEnabledKey, schedule.enabled);
    await p.setInt(scheduleHourKey, schedule.hour);
    await p.setInt(scheduleMinuteKey, schedule.minute);
  }
}
