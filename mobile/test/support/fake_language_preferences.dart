import 'package:lifeos/l10n/language_preference.dart';

/// In-memory [LanguagePreferences] — no shared_preferences platform channel.
class FakeLanguagePreferences implements LanguagePreferences {
  FakeLanguagePreferences({AppLanguage initial = AppLanguage.system}) : _language = initial;

  AppLanguage _language;
  int saves = 0;

  AppLanguage get stored => _language;

  @override
  Future<AppLanguage> load() async => _language;

  @override
  Future<void> save(AppLanguage language) async {
    _language = language;
    saves++;
  }
}
