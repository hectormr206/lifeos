// Proves the forced-backend developer preference: it persists the choice,
// represents "automatic" as ABSENCE (no key), and treats a corrupt/unknown
// stored value as automatic instead of crashing. Uses shared_preferences'
// in-memory mock backing — no platform channel.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_backend_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to automatic (null) when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelBackendPreference();
    expect(await prefs.forcedBackend(), isNull);
  });

  test('persists and reads back a forced backend', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelBackendPreference();

    await prefs.setForcedBackend(LocalLlmBackend.cpu);
    expect(await prefs.forcedBackend(), LocalLlmBackend.cpu);

    await prefs.setForcedBackend(LocalLlmBackend.gpu);
    expect(await prefs.forcedBackend(), LocalLlmBackend.gpu);
  });

  test('automatic is stored as absence, not as a magic string', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelBackendPreference();

    await prefs.setForcedBackend(LocalLlmBackend.cpu);
    await prefs.setForcedBackend(null);

    expect(await prefs.forcedBackend(), isNull);
    final raw = await SharedPreferences.getInstance();
    expect(
      raw.containsKey(SharedPrefsLocalModelBackendPreference.forcedBackendKey),
      isFalse,
    );
  });

  test('an unknown stored value falls back to automatic', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsLocalModelBackendPreference.forcedBackendKey: 'tpu-from-2031',
    });
    final prefs = SharedPrefsLocalModelBackendPreference();
    expect(await prefs.forcedBackend(), isNull);
  });
}
