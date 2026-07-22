import 'package:flutter/material.dart';
import 'package:lifeos/theme/theme_mode_preferences.dart';

/// In-memory [ThemeModePreferences] — no shared_preferences platform channel.
class FakeThemeModePreferences implements ThemeModePreferences {
  FakeThemeModePreferences({ThemeMode initial = ThemeMode.light}) : _mode = initial;

  ThemeMode _mode;
  int saves = 0;

  ThemeMode get stored => _mode;

  @override
  Future<ThemeMode> load() async => _mode;

  @override
  Future<void> save(ThemeMode mode) async {
    _mode = mode;
    saves++;
  }
}
