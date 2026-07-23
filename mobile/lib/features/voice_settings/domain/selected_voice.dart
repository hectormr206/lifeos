import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence of the user's chosen Piper voice id (e.g.
/// `es_MX-claude`). A plain, non-secret UI preference that must survive with no
/// engine connection — same trade as [VoiceSettingsPreferences] — so it lives in
/// `shared_preferences`, not secure storage. Abstracted so the notifier depends
/// on the interface and tests inject a fake without the platform channel.
abstract class SelectedVoicePreferences {
  /// The persisted voice id, or null when the user has never chosen one (the
  /// caller then falls back to the catalog default).
  Future<String?> load();

  /// Persists [voiceId] as the active voice.
  Future<void> save(String voiceId);
}

/// [SelectedVoicePreferences] backed by `shared_preferences`.
class SharedPrefsSelectedVoicePreferences implements SelectedVoicePreferences {
  SharedPrefsSelectedVoicePreferences({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String voiceKey = 'selected_voice_id';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> load() async {
    final prefs = await _instance;
    return prefs.getString(voiceKey);
  }

  @override
  Future<void> save(String voiceId) async {
    final prefs = await _instance;
    await prefs.setString(voiceKey, voiceId);
  }
}
