// The themes have to be READABLE, and readable is a number.
//
// Reported: "la versión light no tiene buen contraste, a diferencia de la dark
// que sí me agrada". Measured, the difference was not a matter of taste:
//
//                          light    dark
//   primary  / surface      1.82    9.62      <- every teal label and icon
//   secondary/ surface      3.00    5.84
//   outline  / surface      4.29    5.80
//
// The brand teal (#00D4AA) is bright, so on a near-white surface it almost
// vanishes, while on the dark surface it sings. WCAG AA asks 4.5:1 for text
// and 3:1 for interface elements; 1.82 is not a close call.
//
// This pins the floor for BOTH themes, so fixing the light one cannot quietly
// break the dark one — which is the half he already likes.
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

/// WCAG 2.1 relative luminance.
double _channel(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// WCAG 2.1 contrast ratio, 1.0 (identical) to 21.0 (black on white).
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final theme in {'claro': lifeosLightTheme, 'oscuro': lifeosDarkTheme}
      .entries) {
    final s = theme.value.colorScheme;

    group('tema ${theme.key}', () {
      test('body text is comfortably readable', () {
        // AAA, not AA: this is the colour of nearly every word in the app.
        expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(7));
      });

      test('secondary text clears AA', () {
        expect(contrast(s.onSurfaceVariant, s.surface),
            greaterThanOrEqualTo(4.5));
      });

      test('the accent is readable as TEXT, not just as a fill', () {
        // `primary` is both the filled-button background AND the colour of
        // every text button, outlined button and list icon. At 1.82 those
        // labels were legible only if you already knew what they said.
        expect(contrast(s.primary, s.surface), greaterThanOrEqualTo(4.5),
            reason: 'teal labels on the surface');
      });

      test('a filled button reads against its own fill', () {
        expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
      });

      test('the second accent is readable too', () {
        expect(contrast(s.secondary, s.surface), greaterThanOrEqualTo(4.5));
      });

      test('borders are visible', () {
        // 3:1 is WCAG's floor for a non-text interface element.
        expect(contrast(s.outline, s.surface), greaterThanOrEqualTo(3));
      });

      test('dividers are visible at all', () {
        // WCAG does not cover decorative separators, so this is a judgement:
        // at 1.62 a divider is a rumour. 1.9 is the point where the eye
        // reliably finds the edge without the line shouting.
        expect(contrast(s.outlineVariant, s.surface), greaterThanOrEqualTo(1.9));
      });

      test('errors stand out', () {
        expect(contrast(s.error, s.surface), greaterThanOrEqualTo(4.5));
      });

      test('text on a card reads as well as on the page', () {
        expect(contrast(s.onSurface, s.surfaceContainerHighest),
            greaterThanOrEqualTo(7));
      });
    });
  }
}
