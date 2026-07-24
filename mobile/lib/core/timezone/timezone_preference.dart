import 'package:shared_preferences/shared_preferences.dart';

/// The user's timezone choice for everything time-scheduled (daily digest,
/// morning briefing, reminders) and every "today" / wall-clock computation.
///
/// Two modes:
///   * AUTOMATIC ([TimezonePreference.automatic]) — follow the device's own
///     IANA zone (DST-aware). This is the DEFAULT, so a current user (who
///     always ran on device time) sees ZERO behavior change.
///   * OVERRIDE ([TimezonePreference.override]) — pin a specific IANA zone id
///     (e.g. `America/New_York`), used regardless of where the phone is.
///
/// Additive + non-destructive (never-corrupt-user-data): a missing key means
/// AUTOMATIC, and switching modes only rewrites this one preference.
class TimezonePreference {
  /// Follow the device zone.
  const TimezonePreference.automatic() : overrideZoneId = null;

  /// Pin the IANA [zoneId] regardless of the device zone.
  const TimezonePreference.override(String zoneId) : overrideZoneId = zoneId;

  /// The pinned IANA zone id, or `null` in AUTOMATIC mode.
  final String? overrideZoneId;

  /// True when following the device zone (no manual override).
  bool get isAutomatic => overrideZoneId == null;

  @override
  bool operator ==(Object other) =>
      other is TimezonePreference && other.overrideZoneId == overrideZoneId;

  @override
  int get hashCode => overrideZoneId.hashCode;

  @override
  String toString() =>
      isAutomatic ? 'TimezonePreference.automatic' : 'TimezonePreference.override($overrideZoneId)';
}

/// Local-only persistence for [TimezonePreference].
///
/// Deliberately NOT `flutter_secure_storage`: the timezone choice is a
/// non-secret UI preference that MUST survive with no engine connection / no
/// pairing. Mirrors [LanguagePreferences]/[ThemeModePreferences]: abstracted so
/// the notifier/resolver depend on the interface and tests inject a fake
/// without the platform channel. Defaults to AUTOMATIC when never set.
abstract class TimezonePreferences {
  /// The persisted choice; AUTOMATIC when never set.
  Future<TimezonePreference> load();

  /// Persists [preference].
  Future<void> save(TimezonePreference preference);
}

/// [TimezonePreferences] backed by `shared_preferences`.
class SharedPrefsTimezonePreferences implements TimezonePreferences {
  SharedPrefsTimezonePreferences({SharedPreferences? prefs}) : _prefs = prefs;

  /// Stores the IANA override id. ABSENT (or empty) → AUTOMATIC. Switching back
  /// to AUTOMATIC removes the key rather than storing a sentinel, keeping the
  /// stored state minimal and additive.
  static const String overrideZoneIdKey = 'timezone_override_zone_id';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<TimezonePreference> load() async {
    final raw = (await _instance).getString(overrideZoneIdKey);
    if (raw == null || raw.isEmpty) return const TimezonePreference.automatic();
    return TimezonePreference.override(raw);
  }

  @override
  Future<void> save(TimezonePreference preference) async {
    final p = await _instance;
    if (preference.isAutomatic) {
      await p.remove(overrideZoneIdKey);
    } else {
      await p.setString(overrideZoneIdKey, preference.overrideZoneId!);
    }
  }
}
