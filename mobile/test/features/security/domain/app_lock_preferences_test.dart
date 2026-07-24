// Proves SharedPrefsAppLockPreferences reads/writes the biometric-app-lock
// toggle and defaults to false (lock OFF, opt-in) when never set — using
// shared_preferences' in-memory mock backing (no real platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/security/domain/app_lock_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to false (lock OFF) when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsAppLockPreferences();
    expect(await prefs.isEnabled(), isFalse);
  });

  test('persists and reads back an enabled value', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsAppLockPreferences();

    await prefs.setEnabled(true);
    expect(await prefs.isEnabled(), isTrue);

    await prefs.setEnabled(false);
    expect(await prefs.isEnabled(), isFalse);
  });

  test('reads an existing persisted value', () async {
    SharedPreferences.setMockInitialValues(
      {SharedPrefsAppLockPreferences.enabledKey: true},
    );
    final prefs = SharedPrefsAppLockPreferences();
    expect(await prefs.isEnabled(), isTrue);
  });
}
