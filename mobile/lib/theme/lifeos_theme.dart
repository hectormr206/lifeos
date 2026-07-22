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
}

/// The default (light) LifeOS theme.
ThemeData get lifeosLightTheme => _buildTheme(_lightColorScheme);

/// The dark LifeOS theme (`#14131F`-based surfaces).
ThemeData get lifeosDarkTheme => _buildTheme(_darkColorScheme);

final ColorScheme _lightColorScheme = ColorScheme.fromSeed(
  seedColor: LifeOSColors.teal,
  brightness: Brightness.light,
).copyWith(
  primary: LifeOSColors.teal,
  // Teal is bright: dark text/icons on it read far better than white.
  onPrimary: LifeOSColors.dark,
  secondary: LifeOSColors.pink,
  onSecondary: Colors.white,
  tertiary: LifeOSColors.softPink,
  onTertiary: LifeOSColors.dark,
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
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
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
