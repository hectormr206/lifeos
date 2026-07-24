// Proves the effective-zone resolver: AUTOMATIC follows the detected device
// zone; a manual override wins over the device; detection failure falls back to
// America/Mexico_City; and an unknown override degrades gracefully.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/timezone/device_timezone.dart';
import 'package:lifeos/core/timezone/effective_timezone.dart';
import 'package:lifeos/core/timezone/timezone_preference.dart';

class _FakePrefs implements TimezonePreferences {
  _FakePrefs(this._pref);
  TimezonePreference _pref;
  @override
  Future<TimezonePreference> load() async => _pref;
  @override
  Future<void> save(TimezonePreference preference) async => _pref = preference;
}

class _FakeDetector implements DeviceTimezoneDetector {
  _FakeDetector(this._id);
  final String? _id;
  @override
  Future<String?> currentZoneId() async => _id;
}

void main() {
  test('AUTOMATIC follows the detected device zone; no override location', () async {
    final resolver = EffectiveTimezoneResolver(
      _FakePrefs(const TimezonePreference.automatic()),
      _FakeDetector('America/New_York'),
    );
    final effective = await resolver.resolve();
    expect(effective.isAutomatic, isTrue);
    expect(effective.zoneId, 'America/New_York');
    expect(effective.detectedZoneId, 'America/New_York');
    // AUTOMATIC → no override applied to wall-clock math (stays device-local).
    expect(effective.overrideLocation, isNull);
  });

  test('manual override wins over the device zone', () async {
    final resolver = EffectiveTimezoneResolver(
      _FakePrefs(const TimezonePreference.override('Europe/Madrid')),
      _FakeDetector('America/Mexico_City'),
    );
    final effective = await resolver.resolve();
    expect(effective.isAutomatic, isFalse);
    expect(effective.zoneId, 'Europe/Madrid');
    // The override location IS applied to wall-clock math.
    expect(effective.overrideLocation, isNotNull);
    expect(effective.overrideLocation!.name, 'Europe/Madrid');
  });

  test('detection failure in AUTOMATIC falls back to America/Mexico_City', () async {
    final resolver = EffectiveTimezoneResolver(
      _FakePrefs(const TimezonePreference.automatic()),
      _FakeDetector(null),
    );
    final effective = await resolver.resolve();
    expect(effective.zoneId, EffectiveTimezoneResolver.fallbackZoneId);
  });

  test('unknown override id degrades to the detected zone', () async {
    final resolver = EffectiveTimezoneResolver(
      _FakePrefs(const TimezonePreference.override('Not/ARealZone')),
      _FakeDetector('America/Mexico_City'),
    );
    final effective = await resolver.resolve();
    expect(effective.zoneId, 'America/Mexico_City');
  });

  test('availableZoneIds returns a sorted, non-empty IANA list', () {
    final ids = EffectiveTimezoneResolver.availableZoneIds();
    expect(ids, contains('America/Mexico_City'));
    expect(ids, contains('America/New_York'));
    final sorted = [...ids]..sort();
    expect(ids, sorted);
  });
}
