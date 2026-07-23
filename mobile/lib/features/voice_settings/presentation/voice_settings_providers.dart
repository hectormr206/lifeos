import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/voice_settings.dart';

/// Local-only persistence of the "Voz" rate/pitch tuning. Overridden with a
/// fake in tests. Lives in its OWN feature (no chat import) so `chat_providers`
/// can read it for gateway construction without an import cycle.
final voiceSettingsPreferencesProvider = Provider<VoiceSettingsPreferences>(
  (ref) => SharedPrefsVoiceSettingsPreferences(),
);

/// The user's persisted [VoiceSettings] (speech rate + curated pitch). Hydrates
/// asynchronously from [voiceSettingsPreferencesProvider] without blocking first
/// read; defaults to the shipped, tuned-for-Piper values until persistence
/// resolves. Read live by the TTS gateways at speak-time so a slider change
/// applies to the next utterance without rebuilding the shared engine.
final voiceSettingsProvider =
    NotifierProvider<VoiceSettingsNotifier, VoiceSettings>(VoiceSettingsNotifier.new);

class VoiceSettingsNotifier extends Notifier<VoiceSettings> {
  Future<void>? _hydration;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  VoiceSettings build() {
    _hydration = _hydrate();
    return const VoiceSettings();
  }

  Future<void> _hydrate() async {
    try {
      state = await ref.read(voiceSettingsPreferencesProvider).load();
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // stay at the safe shipped default rather than crashing.
    }
  }

  /// Sets the speech rate (normalized multiplier) and persists it.
  Future<void> setRate(double rate) => _update(state.copyWith(rate: rate));

  /// Sets the pitch (normalized multiplier) and persists it. No slider in the
  /// minimal UI today, but exposed for a future curated-voice picker.
  Future<void> setPitch(double pitch) => _update(state.copyWith(pitch: pitch));

  Future<void> _update(VoiceSettings next) async {
    state = next;
    try {
      await ref.read(voiceSettingsPreferencesProvider).save(next);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
  }
}
