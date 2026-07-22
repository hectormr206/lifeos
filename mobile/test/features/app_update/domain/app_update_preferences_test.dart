// Proves SharedPrefsAppUpdatePreferences persists the three toggles with the
// right defaults (auto-check ON, notify ON, auto-download OFF) and tracks the
// last-notified marker — using shared_preferences' in-memory mock.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_update_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: auto-check ON, notify ON, auto-download OFF', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsAppUpdatePreferences();
    final s = await prefs.load();
    expect(s.autoCheck, isTrue);
    expect(s.notify, isTrue);
    expect(s.autoDownload, isFalse);
  });

  test('persists and reads back each toggle', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsAppUpdatePreferences();

    await prefs.setAutoCheck(false);
    await prefs.setNotify(false);
    await prefs.setAutoDownload(true);

    final s = await prefs.load();
    expect(s.autoCheck, isFalse);
    expect(s.notify, isFalse);
    expect(s.autoDownload, isTrue);
  });

  test('records and reads the last-notified marker', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsAppUpdatePreferences();

    expect(await prefs.lastNotifiedVersionCode(), isNull);
    await prefs.recordNotified(12, '2026-07-20');
    expect(await prefs.lastNotifiedVersionCode(), 12);
    expect(await prefs.lastNotifiedDay(), '2026-07-20');
  });
}
