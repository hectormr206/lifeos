// Proves the language provider (i18n slice) defaults to system, hydrates from
// persistence, persists + applies a user's choice, resolves the concrete
// locale/code, and defaults `system` to Spanish on a non-English device.
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../support/fake_language_preferences.dart';

void main() {
  ProviderContainer containerWith(FakeLanguagePreferences prefs) {
    final container = ProviderContainer(overrides: [
      languagePreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('defaults to AppLanguage.system before hydration', () {
    final container = containerWith(FakeLanguagePreferences());
    expect(container.read(languageProvider), AppLanguage.system);
  });

  test('hydrates the persisted language on build', () async {
    final container = containerWith(FakeLanguagePreferences(initial: AppLanguage.en));
    expect(container.read(languageProvider), AppLanguage.system);
    await container.read(languageProvider.notifier).ready;
    expect(container.read(languageProvider), AppLanguage.en);
  });

  test('setLanguage updates state and persists', () async {
    final prefs = FakeLanguagePreferences();
    final container = containerWith(prefs);

    await container.read(languageProvider.notifier).setLanguage(AppLanguage.en);

    expect(container.read(languageProvider), AppLanguage.en);
    expect(prefs.stored, AppLanguage.en);
    expect(prefs.saves, 1);
  });

  test('a deliberate choice is not clobbered by a late hydration', () async {
    final prefs = FakeLanguagePreferences(initial: AppLanguage.en);
    final container = containerWith(prefs);

    final notifier = container.read(languageProvider.notifier);
    await notifier.setLanguage(AppLanguage.es);
    await notifier.ready;

    expect(container.read(languageProvider), AppLanguage.es);
  });

  test('localeProvider + appLanguageCodeProvider follow an explicit choice', () async {
    final container = containerWith(FakeLanguagePreferences());

    await container.read(languageProvider.notifier).setLanguage(AppLanguage.en);
    expect(container.read(localeProvider), const Locale('en'));
    expect(container.read(appLanguageCodeProvider), 'en');

    await container.read(languageProvider.notifier).setLanguage(AppLanguage.es);
    expect(container.read(localeProvider), const Locale('es'));
    expect(container.read(appLanguageCodeProvider), 'es');
  });

  test('resolveSystemLocale is English only for an English device, else Spanish', () {
    expect(resolveSystemLocale(const Locale('en')), const Locale('en'));
    expect(resolveSystemLocale(const Locale('en', 'US')), const Locale('en'));
    expect(resolveSystemLocale(const Locale('es')), const Locale('es'));
    // Any other device language falls back to Spanish (the app default).
    expect(resolveSystemLocale(const Locale('fr')), const Locale('es'));
    expect(resolveSystemLocale(const Locale('de')), const Locale('es'));
  });
}
