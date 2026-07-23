import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence for the "Responder por voz" toggle: when on, Axi
/// auto-speaks every new text reply aloud through the on-device TTS engine.
///
/// Abstracted so the chat UI depends on the interface and tests inject a fake
/// without the shared_preferences platform channel.
abstract class VoiceReplyPreferences {
  /// The persisted "respond by voice" value; defaults to `false`.
  Future<bool> isEnabled();

  /// Persists the toggle value.
  Future<void> setEnabled(bool value);
}

/// [VoiceReplyPreferences] backed by `shared_preferences`.
class SharedPrefsVoiceReplyPreferences implements VoiceReplyPreferences {
  SharedPrefsVoiceReplyPreferences({SharedPreferences? prefs}) : _prefs = prefs;

  static const String enabledKey = 'chat_voice_reply_enabled';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<bool> isEnabled() async => (await _instance).getBool(enabledKey) ?? false;

  @override
  Future<void> setEnabled(bool value) async => (await _instance).setBool(enabledKey, value);
}
