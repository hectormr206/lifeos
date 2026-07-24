import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'device_timezone.dart';
import 'timezone_preference.dart';

/// The resolved timezone the app should actually use RIGHT NOW, produced by
/// [EffectiveTimezoneResolver] from the user's [TimezonePreference] and the
/// detected device zone.
class EffectiveTimezone {
  const EffectiveTimezone({
    required this.location,
    required this.isAutomatic,
    this.detectedZoneId,
  });

  /// The effective DST-aware zone: the device zone in AUTOMATIC mode, or the
  /// pinned override otherwise. Always non-null (falls back to Mexico City / UTC
  /// when nothing resolves).
  final tz.Location location;

  /// Whether the effective zone is the device zone (no manual override).
  final bool isAutomatic;

  /// The device's detected IANA id (for read-only display in Settings), or
  /// `null` when detection failed.
  final String? detectedZoneId;

  /// The effective IANA zone id.
  String get zoneId => location.name;

  /// The location to APPLY to wall-clock math (scheduling + "today" windows).
  ///
  /// `null` in AUTOMATIC mode: the device-local `DateTime` already reflects the
  /// device zone, so callers keep their existing (unchanged) device-local math.
  /// The override [location] only when the user pinned a zone — that is the one
  /// case where wall-clock computations must switch away from device-local.
  tz.Location? get overrideLocation => isAutomatic ? null : location;
}

/// Resolves the [EffectiveTimezone] from the persisted [TimezonePreference] and
/// the detected device zone, guaranteeing the `timezone` zone database is loaded
/// first (so any [tz.getLocation]/[tz.TZDateTime] downstream is valid).
class EffectiveTimezoneResolver {
  EffectiveTimezoneResolver(this._prefs, this._detector);

  final TimezonePreferences _prefs;
  final DeviceTimezoneDetector _detector;

  /// Fallback when detection fails AND no override resolves — Héctor's home
  /// zone. Falls back once more to [tz.UTC] if even this id is unknown.
  static const String fallbackZoneId = 'America/Mexico_City';

  /// One-time load of the `timezone` zone database (process-wide, guarded).
  /// Shared with [AppNotifications] which also needs it before scheduling.
  static bool _databaseReady = false;
  static void ensureDatabase() {
    if (_databaseReady) return;
    tzdata.initializeTimeZones();
    _databaseReady = true;
  }

  Future<EffectiveTimezone> resolve() async {
    ensureDatabase();
    final preference = await _prefs.load();
    final detected = await _detector.currentZoneId();

    if (preference.isAutomatic) {
      final location = _locate(detected) ?? _locate(fallbackZoneId) ?? tz.UTC;
      return EffectiveTimezone(location: location, isAutomatic: true, detectedZoneId: detected);
    }

    // Manual override: use the pinned zone; if it is somehow unknown, degrade to
    // the device zone, then the fallback, then UTC — never throw.
    final location = _locate(preference.overrideZoneId) ??
        _locate(detected) ??
        _locate(fallbackZoneId) ??
        tz.UTC;
    return EffectiveTimezone(location: location, isAutomatic: false, detectedZoneId: detected);
  }

  /// Every IANA zone id known to the loaded database, sorted — backs the manual
  /// override picker in Settings.
  static List<String> availableZoneIds() {
    ensureDatabase();
    final ids = tz.timeZoneDatabase.locations.keys.toList()..sort();
    return ids;
  }

  tz.Location? _locate(String? id) {
    if (id == null || id.isEmpty) return null;
    try {
      return tz.getLocation(id);
    } catch (_) {
      return null;
    }
  }
}
