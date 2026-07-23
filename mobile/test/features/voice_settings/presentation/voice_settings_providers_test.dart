// Proves voiceSettingsProvider hydrates from persistence and that setRate /
// setPitch update in-memory state AND persist through the preferences seam —
// with an injected fake (no shared_preferences platform channel).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/voice_settings/domain/voice_settings.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_settings_providers.dart';

/// In-memory [VoiceSettingsPreferences] recording writes.
class FakeVoiceSettingsPreferences implements VoiceSettingsPreferences {
  FakeVoiceSettingsPreferences({VoiceSettings? initial}) : _stored = initial ?? const VoiceSettings();

  VoiceSettings _stored;
  int writes = 0;

  VoiceSettings get stored => _stored;

  @override
  Future<VoiceSettings> load() async => _stored;

  @override
  Future<void> save(VoiceSettings settings) async {
    _stored = settings;
    writes++;
  }
}

void main() {
  test('hydrates the persisted rate/pitch on first read', () async {
    final prefs = FakeVoiceSettingsPreferences(initial: const VoiceSettings(rate: 1.5, pitch: 1.1));
    final container = ProviderContainer(overrides: [
      voiceSettingsPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(voiceSettingsProvider.notifier);
    await notifier.ready;

    expect(container.read(voiceSettingsProvider).rate, 1.5);
    expect(container.read(voiceSettingsProvider).pitch, 1.1);
  });

  test('setRate updates state and persists it', () async {
    final prefs = FakeVoiceSettingsPreferences();
    final container = ProviderContainer(overrides: [
      voiceSettingsPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(voiceSettingsProvider.notifier);
    await notifier.ready;

    await notifier.setRate(1.75);

    expect(container.read(voiceSettingsProvider).rate, 1.75);
    expect(prefs.stored.rate, 1.75);
    expect(prefs.writes, greaterThan(0));
  });

  test('setPitch updates state and persists it', () async {
    final prefs = FakeVoiceSettingsPreferences();
    final container = ProviderContainer(overrides: [
      voiceSettingsPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(voiceSettingsProvider.notifier);
    await notifier.ready;

    await notifier.setPitch(1.3);

    expect(container.read(voiceSettingsProvider).pitch, 1.3);
    expect(prefs.stored.pitch, 1.3);
  });
}
