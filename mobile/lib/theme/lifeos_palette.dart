import 'package:flutter/material.dart';

/// LifeOS accents not represented by Material's semantic color scheme.
@immutable
class LifeOSPalette extends ThemeExtension<LifeOSPalette> {
  const LifeOSPalette({
    required this.axiSkin,
    required this.axiBubble,
    required this.onAxiBubble,
    required this.hairline,
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  final Color axiSkin;
  final Color axiBubble;
  final Color onAxiBubble;
  final Color hairline;
  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color info;
  final Color infoContainer;
  final Color onInfoContainer;

  static const light = LifeOSPalette(
    axiSkin: Color(0xFFFE8FAF),
    axiBubble: Color(0xFFFFD9E3),
    onAxiBubble: Color(0xFF14131F),
    hairline: Color(0xFFEADDE0),
    success: Color(0xFF1E6B3A),
    successContainer: Color(0xFFD6F2DC),
    onSuccessContainer: Color(0xFF0B3B1C),
    warning: Color(0xFF8A5300),
    warningContainer: Color(0xFFFFE6C2),
    onWarningContainer: Color(0xFF4A2C00),
    info: Color(0xFF2D5B8A),
    infoContainer: Color(0xFFDCE8F7),
    onInfoContainer: Color(0xFF102D4B),
  );

  static const dark = LifeOSPalette(
    axiSkin: Color(0xFFFE8FAF),
    axiBubble: Color(0xFF4A1C31),
    onAxiBubble: Color(0xFFFFE3EC),
    hairline: Color(0xFF2E2B42),
    success: Color(0xFF6FD08C),
    successContainer: Color(0xFF1D3B27),
    onSuccessContainer: Color(0xFFC9F2D4),
    warning: Color(0xFFF2B84B),
    warningContainer: Color(0xFF3F2E0E),
    onWarningContainer: Color(0xFFFFE6C2),
    info: Color(0xFF8DB9EA),
    infoContainer: Color(0xFF1C2C40),
    onInfoContainer: Color(0xFFD6E6F8),
  );

  /// Returns the active palette, including when embedded in a plain theme.
  static LifeOSPalette of(BuildContext context) =>
      Theme.of(context).extension<LifeOSPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  LifeOSPalette copyWith({
    Color? axiSkin,
    Color? axiBubble,
    Color? onAxiBubble,
    Color? hairline,
    Color? success,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? info,
    Color? infoContainer,
    Color? onInfoContainer,
  }) =>
      LifeOSPalette(
        axiSkin: axiSkin ?? this.axiSkin,
        axiBubble: axiBubble ?? this.axiBubble,
        onAxiBubble: onAxiBubble ?? this.onAxiBubble,
        hairline: hairline ?? this.hairline,
        success: success ?? this.success,
        successContainer: successContainer ?? this.successContainer,
        onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
        warning: warning ?? this.warning,
        warningContainer: warningContainer ?? this.warningContainer,
        onWarningContainer: onWarningContainer ?? this.onWarningContainer,
        info: info ?? this.info,
        infoContainer: infoContainer ?? this.infoContainer,
        onInfoContainer: onInfoContainer ?? this.onInfoContainer,
      );

  @override
  LifeOSPalette lerp(ThemeExtension<LifeOSPalette>? other, double t) {
    if (other is! LifeOSPalette) return this;
    return LifeOSPalette(
      axiSkin: Color.lerp(axiSkin, other.axiSkin, t)!,
      axiBubble: Color.lerp(axiBubble, other.axiBubble, t)!,
      onAxiBubble: Color.lerp(onAxiBubble, other.onAxiBubble, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer: Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer: Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      onInfoContainer: Color.lerp(onInfoContainer, other.onInfoContainer, t)!,
    );
  }
}
