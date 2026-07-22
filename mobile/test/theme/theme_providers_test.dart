// Proves the theme-mode provider defaults to light, hydrates from persistence,
// and persists + applies a user's choice (app-shell slice).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/theme_providers.dart';

import '../support/fake_theme_mode_preferences.dart';

void main() {
  test('defaults to ThemeMode.light before hydration', () {
    final container = ProviderContainer(overrides: [
      themeModePreferencesProvider.overrideWithValue(FakeThemeModePreferences()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.light);
  });

  test('hydrates the persisted mode on build', () async {
    final container = ProviderContainer(overrides: [
      themeModePreferencesProvider
          .overrideWithValue(FakeThemeModePreferences(initial: ThemeMode.dark)),
    ]);
    addTearDown(container.dispose);

    // First synchronous read is still the default...
    expect(container.read(themeModeProvider), ThemeMode.light);
    await container.read(themeModeProvider.notifier).ready;
    // ...then it flips to the persisted value.
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  test('setThemeMode updates state and persists', () async {
    final prefs = FakeThemeModePreferences();
    final container = ProviderContainer(overrides: [
      themeModePreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark);

    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(prefs.stored, ThemeMode.dark);
    expect(prefs.saves, 1);
  });

  test('a deliberate choice is not clobbered by a late hydration', () async {
    // Persisted value is dark, but the user picks system before hydration lands.
    final prefs = FakeThemeModePreferences(initial: ThemeMode.dark);
    final container = ProviderContainer(overrides: [
      themeModePreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(themeModeProvider.notifier);
    await notifier.setThemeMode(ThemeMode.system);
    await notifier.ready;

    expect(container.read(themeModeProvider), ThemeMode.system);
  });
}
