import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_palette.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

double _channel(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color color) =>
    0.2126 * _channel(color.r) +
    0.7152 * _channel(color.g) +
    0.0722 * _channel(color.b);

double _contrast(Color a, Color b) {
  final x = _luminance(a);
  final y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  for (final theme in [lifeosLightTheme, lifeosDarkTheme]) {
    final palette = theme.extension<LifeOSPalette>()!;
    final surface = theme.colorScheme.surface;
    group(theme.brightness.name, () {
      for (final pair in [
        (palette.onSuccessContainer, palette.successContainer),
        (palette.onWarningContainer, palette.warningContainer),
        (palette.onInfoContainer, palette.infoContainer),
        (palette.onAxiBubble, palette.axiBubble),
      ]) {
        test('container contrast ${pair.$2}', () {
          expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        });
      }
      for (final accent in [palette.success, palette.warning, palette.info]) {
        test('accent contrast $accent', () {
          expect(_contrast(accent, surface), greaterThanOrEqualTo(4.5));
        });
      }
    });
  }
}
