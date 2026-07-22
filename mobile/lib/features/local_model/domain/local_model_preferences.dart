import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence for the "use local model" toggle (roadmap SLICE 1).
///
/// Deliberately NOT `flutter_secure_storage`: this is a non-secret UI
/// preference that MUST survive with no engine connection / no pairing (the
/// whole point of the offline on-device mode). Abstracted so notifiers depend
/// on the interface and tests inject a fake without the platform channel.
abstract class LocalModelPreferences {
  /// The persisted toggle value; defaults to `false` (local mode off) when
  /// never set.
  Future<bool> isEnabled();

  /// Persists the toggle value.
  Future<void> setEnabled(bool value);
}

/// [LocalModelPreferences] backed by `shared_preferences`.
class SharedPrefsLocalModelPreferences implements LocalModelPreferences {
  SharedPrefsLocalModelPreferences({SharedPreferences? prefs}) : _prefs = prefs;

  static const String enabledKey = 'local_model_enabled';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<bool> isEnabled() async => (await _instance).getBool(enabledKey) ?? false;

  @override
  Future<void> setEnabled(bool value) async => (await _instance).setBool(enabledKey, value);
}
