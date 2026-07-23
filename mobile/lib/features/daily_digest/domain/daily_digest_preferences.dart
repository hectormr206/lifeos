import 'package:shared_preferences/shared_preferences.dart';

import 'daily_digest.dart';
import 'daily_digest_schedule.dart';

/// Default, user-editable instruction that shapes the on-device model's
/// natural-language wrap-up over the deterministically-assembled facts. The
/// user can edit it; "restablecer" returns to this text.
const String kDefaultDigestInstructions =
    'Escribe un resumen breve y cálido de mi día en español neutro, a partir de '
    'los registros de hoy. Usa solo los hechos listados; no inventes nada ni '
    'agregues datos. Máximo 4 frases.';

/// Local-only persistence for the on-device DAILY DIGEST: its schedule (an
/// evening auto-run, ON by default), the editable wrap-up instructions, and the
/// last digest the pipeline produced (so it survives navigation + relaunch).
///
/// Same rationale/shape as [MorningBriefingPreferences]: `shared_preferences`
/// (non-secret UI state, must survive with no engine/pairing) and abstract so
/// notifiers depend on the interface and tests inject a fake without the
/// platform channel.
abstract class DailyDigestPreferences {
  /// The digest schedule (ENABLED + 21:00 by default — everything-on rule).
  Future<DailyDigestSchedule> schedule();

  Future<void> saveSchedule(DailyDigestSchedule schedule);

  /// The user's wrap-up instructions ([kDefaultDigestInstructions] until edited).
  Future<String> instructions();

  Future<void> saveInstructions(String instructions);

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
  static const String instructionsKey = 'daily_digest_instructions';
  static const String lastDigestKey = 'daily_digest_last';

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
  Future<String> instructions() async {
    final p = await _instance;
    final saved = p.getString(instructionsKey);
    return (saved == null || saved.trim().isEmpty) ? kDefaultDigestInstructions : saved;
  }

  @override
  Future<void> saveInstructions(String instructions) async =>
      (await _instance).setString(instructionsKey, instructions);

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
