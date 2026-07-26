import 'package:shared_preferences/shared_preferences.dart';

import 'daily_digest_schedule.dart';

/// Local-only persistence for the daily-digest SCHEDULE (an evening auto-run,
/// ON by default). The narration instruction is a fixed internal constant
/// ([kDailyDigestNarrationInstruction]) and is deliberately NOT persisted here —
/// it is neither user-editable nor surfaced.
///
/// ONLY SETTINGS live here (`shared_preferences` — non-secret UI state that
/// must survive with no engine/pairing). The digest CONTENT (the last generated
/// digest — a model narration over the user's life) is USER CONTENT and lives
/// ENCRYPTED in the graph DB via `GraphDailyDigestContentStore`; it must never
/// sit in plain prefs.
abstract class DailyDigestPreferences {
  /// The digest schedule (ENABLED + 21:00 by default — everything-on rule).
  Future<DailyDigestSchedule> schedule();

  Future<void> saveSchedule(DailyDigestSchedule schedule);
}

/// [DailyDigestPreferences] backed by `shared_preferences`.
class SharedPrefsDailyDigestPreferences implements DailyDigestPreferences {
  SharedPrefsDailyDigestPreferences({SharedPreferences? prefs})
    : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String scheduleEnabledKey = 'daily_digest_schedule_enabled';
  static const String scheduleHourKey = 'daily_digest_schedule_hour';
  static const String scheduleMinuteKey = 'daily_digest_schedule_minute';

  /// LEGACY (pre-encryption) location of the last digest, kept ONLY so the
  /// migration in `GraphDailyDigestContentStore` and the defensive wipe purge
  /// can find/remove it. Never written anymore.
  static const String legacyLastDigestKey = 'daily_digest_last';
  // NOTE: a legacy 'daily_digest_instructions' key may still exist on disk from
  // older builds. It is intentionally never read or written now — a stale value
  // is harmless and is simply ignored (never-corrupt-user-data: no migration
  // deletes it).

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<DailyDigestSchedule> schedule() async {
    final p = await _instance;
    // Absent key (first run) → DEFAULT ON (everything-on rule): the user opts
    // out, so a never-set schedule is enabled at the default hour.
    return DailyDigestSchedule(
      enabled: p.getBool(scheduleEnabledKey) ?? true,
      hour: p.getInt(scheduleHourKey) ?? DailyDigestSchedule.defaultHour,
      minute: p.getInt(scheduleMinuteKey) ?? DailyDigestSchedule.defaultMinute,
    );
  }

  @override
  Future<void> saveSchedule(DailyDigestSchedule schedule) async {
    final p = await _instance;
    await p.setBool(scheduleEnabledKey, schedule.enabled);
    await p.setInt(scheduleHourKey, schedule.hour);
    await p.setInt(scheduleMinuteKey, schedule.minute);
  }
}
