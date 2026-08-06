import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence for the app's [ThemeMode] (app-shell slice).
///
/// Deliberately NOT `flutter_secure_storage`: the light/dark choice is a
/// non-secret UI preference that MUST survive with no engine connection / no
/// pairing. Mirrors `LocalModelPreferences`: abstracted so the notifier
/// depends on the interface and tests inject a fake without the platform
/// channel. Defaults to [ThemeMode.system] when never set — the app should
/// look like the rest of the machine before the user has said anything.
abstract class ThemeModePreferences {
  /// The persisted mode; [ThemeMode.system] when never set.
  Future<ThemeMode> load();

  /// Persists [mode].
  Future<void> save(ThemeMode mode);
}

/// [ThemeModePreferences] backed by `shared_preferences`.
class SharedPrefsThemeModePreferences implements ThemeModePreferences {
  SharedPrefsThemeModePreferences({this._prefs});

  static const String modeKey = 'theme_mode';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<ThemeMode> load() async {
    final raw = (await _instance).getString(modeKey);
    return _decode(raw);
  }

  @override
  Future<void> save(ThemeMode mode) async => (await _instance).setString(modeKey, _encode(mode));

  static String _encode(ThemeMode mode) => switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
      };

  static ThemeMode _decode(String? raw) => switch (raw) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        // Unknown / never-set → the app default is LIGHT.
        _ => ThemeMode.system,
      };
}
