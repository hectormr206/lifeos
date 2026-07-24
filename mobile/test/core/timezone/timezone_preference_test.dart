// Proves the timezone preference persistence: default AUTOMATIC, an override
// round-trips by IANA id, and a missing key (never set) → AUTOMATIC. Additive,
// non-destructive (never-corrupt-user-data).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/timezone/timezone_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing key → AUTOMATIC (default)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsTimezonePreferences();
    final loaded = await prefs.load();
    expect(loaded.isAutomatic, isTrue);
    expect(loaded, const TimezonePreference.automatic());
  });

  test('override persists and round-trips by id', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsTimezonePreferences();

    await prefs.save(const TimezonePreference.override('America/New_York'));
    final loaded = await prefs.load();
    expect(loaded.isAutomatic, isFalse);
    expect(loaded.overrideZoneId, 'America/New_York');
  });

  test('switching back to AUTOMATIC clears the stored override', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsTimezonePreferences.overrideZoneIdKey: 'Europe/Madrid',
    });
    final prefs = SharedPrefsTimezonePreferences();
    expect((await prefs.load()).overrideZoneId, 'Europe/Madrid');

    await prefs.save(const TimezonePreference.automatic());
    expect((await prefs.load()).isAutomatic, isTrue);
  });

  test('empty stored id is treated as AUTOMATIC (not a bogus override)', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsTimezonePreferences.overrideZoneIdKey: '',
    });
    final prefs = SharedPrefsTimezonePreferences();
    expect((await prefs.load()).isAutomatic, isTrue);
  });
}
