import 'package:shared_preferences/shared_preferences.dart';

/// The user's language choice for the whole app (i18n slice).
///
/// [system] follows the device language, resolving to a concrete supported
/// locale (Spanish unless the device is English — see `locale_providers.dart`).
/// [es]/[en] pin a language explicitly. ADDING A LANGUAGE later = add a value
/// here, an ARB file, and a selector option; the persistence below round-trips
/// any value by its [name].
enum AppLanguage { system, es, en }

/// Local-only persistence for the [AppLanguage] preference (i18n slice).
///
/// Deliberately NOT `flutter_secure_storage`: the language choice is a
/// non-secret UI preference that MUST survive with no engine connection / no
/// pairing. Mirrors [ThemeModePreferences]: abstracted so the notifier depends
/// on the interface and tests inject a fake without the platform channel.
/// Defaults to [AppLanguage.system] when never set.
abstract class LanguagePreferences {
  /// The persisted language; [AppLanguage.system] when never set.
  Future<AppLanguage> load();

  /// Persists [language].
  Future<void> save(AppLanguage language);
}

/// [LanguagePreferences] backed by `shared_preferences`.
class SharedPrefsLanguagePreferences implements LanguagePreferences {
  SharedPrefsLanguagePreferences({this._prefs});

  static const String languageKey = 'app_language';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<AppLanguage> load() async {
    final raw = (await _instance).getString(languageKey);
    return _decode(raw);
  }

  @override
  Future<void> save(AppLanguage language) async =>
      (await _instance).setString(languageKey, language.name);

  static AppLanguage _decode(String? raw) {
    for (final value in AppLanguage.values) {
      if (value.name == raw) return value;
    }
    // Unknown / never-set → follow the system language.
    return AppLanguage.system;
  }
}
