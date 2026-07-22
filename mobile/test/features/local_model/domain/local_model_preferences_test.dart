// Proves SharedPrefsLocalModelPreferences (roadmap SLICE 1) reads/writes the
// toggle and defaults to false when never set — using shared_preferences'
// in-memory mock backing (no real platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_model_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to false when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelPreferences();
    expect(await prefs.isEnabled(), isFalse);
  });

  test('persists and reads back an enabled value', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelPreferences();

    await prefs.setEnabled(true);
    expect(await prefs.isEnabled(), isTrue);

    await prefs.setEnabled(false);
    expect(await prefs.isEnabled(), isFalse);
  });

  test('reads an existing persisted value', () async {
    SharedPreferences.setMockInitialValues({SharedPrefsLocalModelPreferences.enabledKey: true});
    final prefs = SharedPrefsLocalModelPreferences();
    expect(await prefs.isEnabled(), isTrue);
  });
}
