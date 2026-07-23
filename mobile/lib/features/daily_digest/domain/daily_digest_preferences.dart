import 'package:shared_preferences/shared_preferences.dart';

import 'daily_digest.dart';
import 'daily_digest_schedule.dart';

/// Local-only persistence for the on-device DAILY DIGEST: its schedule (an
/// evening auto-run, ON by default) and the last digest the pipeline produced
/// (so it survives navigation + relaunch). The narration instruction is a fixed
/// internal constant ([kDailyDigestNarrationInstruction]) and is deliberately
/// NOT persisted here — it is neither user-editable nor surfaced.
///
/// Same rationale/shape as [MorningBriefingPreferences]: `shared_preferences`
/// (non-secret UI state, must survive with no engine/pairing) and abstract so
/// notifiers depend on the interface and tests inject a fake without the
/// platform channel.
abstract class DailyDigestPreferences {
  /// The digest schedule (ENABLED + 21:00 by default — everything-on rule).
  Future<DailyDigestSchedule> schedule();

  Future<void> saveSchedule(DailyDigestSchedule schedule);

  /// The last digest produced, or null if never run.
  Future<DailyDigest?> lastDigest();

  Future<void> saveLastDigest(DailyDigest digest);
}

/// [DailyDigestPreferences] backed by `shared_preferences`.
class SharedPrefsDailyDigestPreferences implements DailyDigestPreferences {
  SharedPrefsDailyDigestPreferences({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String scheduleEnabledKey = 'daily_digest_schedule_enabled';
  static const String scheduleHourKey = 'daily_digest_schedule_hour';
  static const String scheduleMinuteKey = 'daily_digest_schedule_minute';
  static const String lastDigestKey = 'daily_digest_last';
  // NOTE: a legacy 'daily_digest_instructions' key may still exist on disk from
  // older builds. It is intentionally never read or written now — a stale value
  // is harmless and is simply ignored (never-corrupt-user-data: no migration
  // deletes it).

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

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

  @override
  Future<DailyDigest?> lastDigest() async {
    final raw = (await _instance).getString(lastDigestKey);
    if (raw == null) return null;
    return DailyDigest.decode(raw);
  }

  @override
  Future<void> saveLastDigest(DailyDigest digest) async =>
      (await _instance).setString(lastDigestKey, digest.encode());
}
