import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'language_preference.dart';

/// Resolves the device language to a concrete SUPPORTED locale.
///
/// The rule (i18n slice): English when the device is English, otherwise
/// Spanish. This is what makes `AppLanguage.system` default to `es` on a
/// non-English device. Extracted as a pure-ish function (the platform locale is
/// the only side input) so a new language just extends the mapping here.
Locale resolveSystemLocale([Locale? deviceLocale]) {
  final code = (deviceLocale ?? PlatformDispatcher.instance.locale).languageCode;
  return switch (code) {
    'en' => const Locale('en'),
    _ => const Locale('es'),
  };
}

/// Persistence for the [AppLanguage] preference. Overridden with a fake in tests.
final languagePreferencesProvider =
    Provider<LanguagePreferences>((ref) => SharedPrefsLanguagePreferences());

/// The current [AppLanguage] choice (system/es/en).
///
/// Exposes a synchronous value (default [AppLanguage.system]) so the root
/// widget can read it without awaiting; the persisted value is hydrated
/// asynchronously in [LanguageNotifier.build] and flips the state once known.
/// Same async-load-vs-write race guard as `ThemeModeNotifier`.
final languageProvider =
    NotifierProvider<LanguageNotifier, AppLanguage>(LanguageNotifier.new);

class LanguageNotifier extends Notifier<AppLanguage> {
  /// Set once the user explicitly picks a language, so a late-resolving
  /// hydration read never clobbers a deliberate choice.
  bool _userSet = false;

  Future<void>? _hydration;

  /// Lets tests await the initial persistence read deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  AppLanguage build() {
    _hydration = _hydrate();
    return AppLanguage.system;
  }

  Future<void> _hydrate() async {
    try {
      final stored = await ref.read(languagePreferencesProvider).load();
      if (!_userSet) state = stored;
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // keep the safe default (system) rather than crashing.
    }
  }

  /// Sets + persists the language (Región selector in Settings).
  Future<void> setLanguage(AppLanguage language) async {
    _userSet = true;
    state = language;
    await ref.read(languagePreferencesProvider).save(language);
  }
}

/// The concrete [Locale] to hand `MaterialApp` — always a supported locale,
/// never null: `system` is resolved via [resolveSystemLocale]. Because it is
/// always concrete, the app never depends on Flutter's supported-locale
/// fallback ordering.
final localeProvider = Provider<Locale>((ref) {
  final language = ref.watch(languageProvider);
  return switch (language) {
    AppLanguage.es => const Locale('es'),
    AppLanguage.en => const Locale('en'),
    AppLanguage.system => resolveSystemLocale(),
  };
});

/// The current language code ('es' / 'en') — the single source of truth for
/// Axi's reply language and the TTS voice locale. Derived from [localeProvider]
/// so it tracks the same system-resolution rule.
final appLanguageCodeProvider = Provider<String>((ref) => ref.watch(localeProvider).languageCode);
