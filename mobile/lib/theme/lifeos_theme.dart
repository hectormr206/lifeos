import 'package:flutter/material.dart';

/// LifeOS brand palette + Material 3 light/dark themes (app-shell slice).
///
/// The colors are lifted straight from the Axi axolotl mark
/// (`axi/src/axi/static/axi-mark.svg`): teal is the primary brand color, pink
/// the accent/secondary, soft pink a supporting tint, and the near-black
/// `#14131F` drives dark surfaces + on-light text. Both themes are built from
/// a seeded [ColorScheme] (so containers/tones stay harmonious) with the brand
/// primary/secondary/tertiary pinned on top for an exact-match identity.
class LifeOSColors {
  const LifeOSColors._();

  /// Primary brand color — teal.
  static const Color teal = Color(0xFF00D4AA);

  /// Accent / secondary — pink.
  static const Color pink = Color(0xFFFF4D88);

  /// Supporting tint — soft pink (the axolotl body).
  static const Color softPink = Color(0xFFFE8FAF);

  /// Near-black — dark surfaces + on-light/on-teal text.
  static const Color dark = Color(0xFF14131F);

  /// A hair-lighter dark for elevated surfaces/cards in the dark theme.
  static const Color darkSurfaceHigh = Color(0xFF201E2E);

  /// The brand teal DARKENED for use on a light surface.
  ///
  /// #00D4AA is bright by design and sings against the dark theme, but on a
  /// near-white surface it measures 1.82:1 — WCAG asks 4.5:1 for text and 3:1
  /// for controls, and every text button, outlined button and list icon in the
  /// app is painted with it. Reported as "la versión light no tiene buen
  /// contraste"; it was not a matter of taste.
  ///
  /// Same hue, HCT tone 42, which measures 5.7:1 on the light surface and
  /// takes white text at 6.0:1. The bright teal is still what fills a button —
  /// as a FILL it is excellent (9.6:1 with the near-black on top).
  static const Color tealOnLight = Color(0xFF007159);

  /// The brand pink darkened for a light surface, same reasoning: 3.0 -> 5.7.
  static const Color pinkOnLight = Color(0xFFC0155B);

  /// Divider colour for the light theme.
  ///
  /// The seeded outlineVariant measured 1.62:1, which makes a separator a
  /// rumour — half of why the light theme read as washed out. HCT tone 62 of
  /// the brand hue: 2.83:1, an edge the eye finds without the line shouting.
  static const Color dividerOnLight = Color(0xFF8E9893);
}

/// The default (light) LifeOS theme.
ThemeData get lifeosLightTheme => _buildTheme(_lightColorScheme);

/// The dark LifeOS theme (`#14131F`-based surfaces).
ThemeData get lifeosDarkTheme => _buildTheme(_darkColorScheme);

final ColorScheme _lightColorScheme = ColorScheme.fromSeed(
  seedColor: LifeOSColors.teal,
  brightness: Brightness.light,
).copyWith(
  // The DARKENED brand colours, because in the light theme these tokens are
  // read as text far more often than they are seen as a fill.
  primary: LifeOSColors.tealOnLight,
  onPrimary: Colors.white,
  secondary: LifeOSColors.pinkOnLight,
  onSecondary: Colors.white,
  tertiary: LifeOSColors.pinkOnLight,
  onTertiary: Colors.white,
  outlineVariant: LifeOSColors.dividerOnLight,
);

final ColorScheme _darkColorScheme = ColorScheme.fromSeed(
  seedColor: LifeOSColors.teal,
  brightness: Brightness.dark,
).copyWith(
  primary: LifeOSColors.teal,
  onPrimary: LifeOSColors.dark,
  secondary: LifeOSColors.pink,
  onSecondary: Colors.white,
  tertiary: LifeOSColors.softPink,
  onTertiary: LifeOSColors.dark,
  surface: LifeOSColors.dark,
  surfaceContainerHighest: LifeOSColors.darkSurfaceHigh,
);

ThemeData _buildTheme(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: isDark ? 0 : 2,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // The bright brand teal in BOTH themes, with the near-black on top:
        // 9.6:1, and the button is the one place the brand colour should be
        // loud. Only the text-sized uses of `primary` were darkened.
        backgroundColor: LifeOSColors.teal,
        foregroundColor: LifeOSColors.dark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
    ),
  );
}
