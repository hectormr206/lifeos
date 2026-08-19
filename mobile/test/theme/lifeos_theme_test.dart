// Proves the LifeOS brand themes carry the exact axolotl-mark palette and are
// Material 3, in both light and dark (app-shell slice).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

void main() {
  test('light theme is Material 3, light brightness, brand accents darkened',
      () {
    // The light theme carries the brand hues at a DARKER tone. The bright
    // #00D4AA measured 1.82:1 on the near-white surface, and `primary` is the
    // colour of every text button, outlined button and list icon — the floor
    // those have to clear is pinned in contrast_test.dart. The bright teal is
    // still what fills a button; see LifeOSColors.tealOnLight.
    final theme = lifeosLightTheme;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, LifeOSColors.tealOnLight);
    expect(theme.colorScheme.secondary, LifeOSColors.pinkOnLight);
  });

  test('the darkened accents keep the brand HUE, not just some dark colour',
      () {
    // A "readable" accent that is no longer teal would fix the number and lose
    // the identity — the axolotl mark is the reason these colours exist.
    final teal = HSLColor.fromColor(LifeOSColors.teal);
    final dark = HSLColor.fromColor(LifeOSColors.tealOnLight);
    expect((dark.hue - teal.hue).abs(), lessThan(12));
    expect(dark.lightness, lessThan(teal.lightness));
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
