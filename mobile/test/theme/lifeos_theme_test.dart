// Proves the LifeOS brand themes carry the exact axolotl-mark palette and are
// Material 3, in both light and dark (app-shell slice).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

void main() {
  test('light theme is Material 3, light brightness, teal primary + pink secondary', () {
    final theme = lifeosLightTheme;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, LifeOSColors.teal);
    expect(theme.colorScheme.secondary, LifeOSColors.pink);
  });

  test('dark theme is Material 3, dark brightness, dark surface, teal primary', () {
    final theme = lifeosDarkTheme;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, LifeOSColors.teal);
    expect(theme.colorScheme.secondary, LifeOSColors.pink);
    expect(theme.colorScheme.surface, LifeOSColors.dark);
  });

  test('brand palette values match the axolotl mark', () {
    expect(LifeOSColors.teal, const Color(0xFF00D4AA));
    expect(LifeOSColors.pink, const Color(0xFFFF4D88));
    expect(LifeOSColors.softPink, const Color(0xFFFE8FAF));
    expect(LifeOSColors.dark, const Color(0xFF14131F));
  });
}
