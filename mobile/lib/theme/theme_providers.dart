import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_mode_preferences.dart';

/// Persistence for the [ThemeMode] preference. Overridden with a fake in tests.
final themeModePreferencesProvider =
    Provider<ThemeModePreferences>((ref) => SharedPrefsThemeModePreferences());

/// The active [ThemeMode] for `MaterialApp.router`.
///
/// Exposes a synchronous [ThemeMode] (default [ThemeMode.light]) so the root
/// widget can read it without awaiting; the persisted value is hydrated
/// asynchronously in [ThemeModeNotifier.build] and flips the state once known.
/// Same async-load-vs-write race guard as `LocalModelEnabledNotifier`.
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  /// Set once the user explicitly picks a mode, so a late-resolving hydration
  /// read never clobbers a deliberate choice.
  bool _userSet = false;

  Future<void>? _hydration;

  /// Lets tests await the initial persistence read deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  ThemeMode build() {
    // Default LIGHT; hydrate from persistence without blocking first read.
    _hydration = _hydrate();
    return ThemeMode.light;
  }

  Future<void> _hydrate() async {
    final stored = await ref.read(themeModePreferencesProvider).load();
    if (!_userSet) state = stored;
  }

  /// Sets + persists the theme mode (Apariencia selector in Settings).
  Future<void> setThemeMode(ThemeMode mode) async {
    _userSet = true;
    state = mode;
    await ref.read(themeModePreferencesProvider).save(mode);
  }
}
