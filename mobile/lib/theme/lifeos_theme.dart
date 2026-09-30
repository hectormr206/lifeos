import 'package:flutter/material.dart';

import 'lifeos_palette.dart';
import 'lifeos_tokens.dart';

/// Brand colors lifted from the Axi axolotl mark
/// (`axi/src/axi/static/axi-mark.svg`). The full token set lives in the color
/// schemes below and in [LifeOSPalette]; see docs/design-system.md.
class LifeOSColors {
  const LifeOSColors._();

  /// Gill teal: the action color. Excellent as a FILL (9.6:1 under [dark]).
  static const Color teal = Color(0xFF00D4AA);

  /// Accent pink.
  static const Color pink = Color(0xFFFF4D88);

  /// Axi's skin: reserved for Axi's own presence (avatar, bubbles).
  static const Color softPink = Color(0xFFFE8FAF);

  /// Axi's eyes: ink on light surfaces and the dark theme's page.
  static const Color dark = Color(0xFF14131F);

  /// A lifted dark surface for containers in the dark theme.
  static const Color darkSurfaceHigh = Color(0xFF201E2E);

  /// [teal] darkened for text on light surfaces. The bright teal measures
  /// 1.82:1 on a near-white page (WCAG asks 4.5:1 for text); this keeps the
  /// hue at 5.5:1. Pinned by test/theme/contrast_test.dart.
  static const Color tealOnLight = Color(0xFF007159);

  /// [pink] darkened for text on light surfaces, same reasoning: 3.0 -> 5.6.
  static const Color pinkOnLight = Color(0xFFC0155B);

  /// Light-theme divider: 2.0:1, an edge the eye finds without the line
  /// shouting (the seeded default measured 1.62:1).
  static const Color dividerOnLight = Color(0xFFBFAAB2);
}

/// The default (light) LifeOS theme.
ThemeData get lifeosLightTheme => _buildTheme(_lightColorScheme);

/// The dark LifeOS theme, preserving the near-black page.
ThemeData get lifeosDarkTheme => _buildTheme(_darkColorScheme);

final ColorScheme _lightColorScheme = ColorScheme.fromSeed(
  seedColor: LifeOSColors.teal,
  brightness: Brightness.light,
).copyWith(
  surface: const Color(0xFFFBF5F4),
  onSurface: LifeOSColors.dark,
  onSurfaceVariant: const Color(0xFF6B5560),
  outline: const Color(0xFF8A7680),
  outlineVariant: LifeOSColors.dividerOnLight,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: const Color(0xFFF7EFEF),
  surfaceContainer: const Color(0xFFF2E8E9),
  surfaceContainerHigh: const Color(0xFFEDE1E3),
  surfaceContainerHighest: const Color(0xFFE9DADD),
  primary: LifeOSColors.tealOnLight,
  onPrimary: Colors.white,
  primaryContainer: const Color(0xFFCFF5EA),
  onPrimaryContainer: const Color(0xFF00382B),
  secondary: LifeOSColors.pinkOnLight,
  onSecondary: Colors.white,
  secondaryContainer: const Color(0xFFFFD9E3),
  onSecondaryContainer: const Color(0xFF3E0A20),
  tertiary: LifeOSColors.pinkOnLight,
  onTertiary: Colors.white,
  inverseSurface: const Color(0xFF2B2A3A),
  onInverseSurface: const Color(0xFFF3EEF8),
  inversePrimary: LifeOSColors.teal,
);

final ColorScheme _darkColorScheme = ColorScheme.fromSeed(
  seedColor: LifeOSColors.teal,
  brightness: Brightness.dark,
).copyWith(
  surface: LifeOSColors.dark,
  onSurface: const Color(0xFFF3EEF8),
  onSurfaceVariant: const Color(0xFFB7B2CC),
  outline: const Color(0xFF8C88A0),
  outlineVariant: const Color(0xFF4A4663),
  surfaceContainerLowest: const Color(0xFF0F0E18),
  surfaceContainerLow: const Color(0xFF1A1927),
  surfaceContainer: LifeOSColors.darkSurfaceHigh,
  surfaceContainerHigh: const Color(0xFF282638),
  surfaceContainerHighest: const Color(0xFF2E2B42),
  primary: LifeOSColors.teal,
  onPrimary: LifeOSColors.dark,
  primaryContainer: const Color(0xFF00513F),
  onPrimaryContainer: const Color(0xFF9FF2DA),
  secondary: LifeOSColors.pink,
  onSecondary: LifeOSColors.dark,
  secondaryContainer: const Color(0xFF5C1F3A),
  onSecondaryContainer: const Color(0xFFFFD9E3),
  tertiary: LifeOSColors.softPink,
  onTertiary: LifeOSColors.dark,
  inverseSurface: const Color(0xFFF3EEF8),
  onInverseSurface: LifeOSColors.dark,
  inversePrimary: LifeOSColors.tealOnLight,
);

const _display = 'BricolageGrotesque';
const _reading = 'AtkinsonHyperlegibleNext';

TextTheme _type(ColorScheme scheme) => TextTheme(
      displayLarge: const TextStyle(fontFamily: _display, fontSize: 57, height: 64 / 57, fontWeight: FontWeight.w800, letterSpacing: -1),
      displayMedium: const TextStyle(fontFamily: _display, fontSize: 45, height: 52 / 45, fontWeight: FontWeight.w800, letterSpacing: -0.8),
      displaySmall: const TextStyle(fontFamily: _display, fontSize: 36, height: 42 / 36, fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineLarge: const TextStyle(fontFamily: _display, fontSize: 32, height: 38 / 32, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: const TextStyle(fontFamily: _display, fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w700, letterSpacing: -0.4),
      headlineSmall: const TextStyle(fontFamily: _display, fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: const TextStyle(fontFamily: _display, fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: const TextStyle(fontFamily: _reading, fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: 0),
      titleSmall: const TextStyle(fontFamily: _reading, fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w700, letterSpacing: 0),
      bodyLarge: const TextStyle(fontFamily: _reading, fontSize: 17, height: 26 / 17, fontWeight: FontWeight.w400, letterSpacing: 0),
      bodyMedium: const TextStyle(fontFamily: _reading, fontSize: 15, height: 22 / 15, fontWeight: FontWeight.w400, letterSpacing: 0),
      bodySmall: const TextStyle(fontFamily: _reading, fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w400, letterSpacing: 0),
      labelLarge: const TextStyle(fontFamily: _reading, fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w700, letterSpacing: 0),
      labelMedium: const TextStyle(fontFamily: _reading, fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w600, letterSpacing: 0),
      labelSmall: const TextStyle(fontFamily: _reading, fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, letterSpacing: 0),
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

ThemeData _buildTheme(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  final type = _type(scheme);
  final dialogColor = isDark ? scheme.surfaceContainer : scheme.surfaceContainerLowest;
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.input),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [isDark ? LifeOSPalette.dark : LifeOSPalette.light],
    fontFamily: _reading,
    textTheme: type,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: type.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Bright brand teal fills the action in BOTH themes; dark ink stays
        // legible on it. Scheme.primary is darker in light mode for text.
        backgroundColor: LifeOSColors.teal,
        foregroundColor: LifeOSColors.dark,
        disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: type.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.outline),
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: type.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        shape: const StadiumBorder(),
        textStyle: type.labelLarge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurface,
        shape: const StadiumBorder(),
        elevation: 0,
        minimumSize: const Size(64, 48),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: LifeOSColors.teal,
      foregroundColor: LifeOSColors.dark,
      elevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dialogColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: isDark ? BorderSide.none : BorderSide(color: LifeOSPalette.light.hairline),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: isDark ? scheme.surfaceContainer : scheme.surfaceContainerLow,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: scheme.primary, width: 2)),
      errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: scheme.error)),
      focusedErrorBorder: inputBorder.copyWith(borderSide: BorderSide(color: scheme.error, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.chip)),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: type.labelMedium,
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(StadiumBorder())),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.panel)),
      backgroundColor: dialogColor,
      titleTextStyle: type.headlineSmall,
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.panel))),
      backgroundColor: dialogColor,
      dragHandleColor: scheme.outline,
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.input)),
      color: dialogColor,
      elevation: 2,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: type.bodyMedium?.copyWith(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.input)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    tabBarTheme: TabBarThemeData(
      indicatorColor: scheme.primary,
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: type.labelLarge,
      dividerColor: scheme.outlineVariant,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHigh,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: type.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
  );
}
