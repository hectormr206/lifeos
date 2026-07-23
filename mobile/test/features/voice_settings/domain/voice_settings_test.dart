// Proves VoiceSettings maps the normalized rate/pitch multipliers onto each
// engine's native scale, and that SharedPrefsVoiceSettingsPreferences
// round-trips rate/pitch (defaulting to the shipped values when nothing is
// stored) — using shared_preferences' in-memory mock (no platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/voice_settings/domain/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceSettings mapping', () {
    test('the shipped default is a natural (1.0) rate and neutral pitch', () {
      const s = VoiceSettings();
      expect(s.rate, VoiceSettings.defaultRate);
      expect(s.pitch, VoiceSettings.defaultPitch);
      // Piper speed passes the multiplier straight through.
      expect(s.piperSpeed, 1.0);
      // flutter_tts reads naturally at ~0.5 for a 1.0 multiplier.
      expect(s.systemRate, 0.5);
      expect(s.systemPitch, 1.0);
    });

    test('a faster multiplier scales both engines and clamps to valid ranges', () {
      const s = VoiceSettings(rate: 2.0, pitch: 2.0);
      expect(s.piperSpeed, 2.0);
      expect(s.systemRate, 1.0); // (0.5 * 2.0) clamped to the plugin's 0..1
      expect(s.systemPitch, 2.0);
    });

    test('a slower multiplier scales down', () {
      const s = VoiceSettings(rate: 0.5);
      expect(s.piperSpeed, 0.5);
      expect(s.systemRate, 0.25);
    });
  });

  group('SharedPrefsVoiceSettingsPreferences', () {
    test('defaults to the shipped rate/pitch when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPrefsVoiceSettingsPreferences();

      final s = await prefs.load();
      expect(s.rate, VoiceSettings.defaultRate);
      expect(s.pitch, VoiceSettings.defaultPitch);
    });

    test('persists and reads back rate + pitch', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPrefsVoiceSettingsPreferences();

      await prefs.save(const VoiceSettings(rate: 1.5, pitch: 1.2));

      final loaded = await prefs.load();
      expect(loaded.rate, 1.5);
      expect(loaded.pitch, 1.2);
    });
  });
}
