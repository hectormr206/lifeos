// Proves the NATIVE pose math behind Axi's animated body reproduces the CSS
// keyframes the deleted WebView asset used to run:
//
//   blink      5.5s  0%,92%,100% scaleY(1)          96% scaleY(0.1)
//   gillFloat  4.0s  0%,100% rotate(-2deg)          50% rotate(2deg)
//   heartbeat  2.0s  0%,18%,30%,100% scale(1)       9% 1.18  24% 1.12
//   tailWag    4.5s  0%,100% rotate(-3deg)          50% rotate(7deg)
//   mindPulse  2.6s  0%,100% opacity .22            50% opacity .5
//   mindSpark  2.0s  0%,100% op .35 / y 0 / s .85   50% op 1 / y -1 / s 1.1
//
// Every keyframe stop is asserted exactly; between stops we assert the
// direction of travel and the bounds, which is what `ease-in-out` guarantees.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_animation.dart';

double _deg(double radians) => radians * 180 / math.pi;

void main() {
  group('blink (5.5s)', () {
    test('eyes are wide open for the whole first 92% of the cycle', () {
      for (final t in [0.0, 1.0, 3.0, 5.5 * 0.92]) {
        expect(axiAvatarPoseAt(t).blinkScaleY, closeTo(1.0, 1e-9), reason: '$t');
      }
    });

    test('the lid is fully shut at 96% of the cycle', () {
      expect(axiAvatarPoseAt(5.5 * 0.96).blinkScaleY, closeTo(0.1, 1e-9));
    });

    test('the lid closes then reopens inside the last 8%', () {
      final closing = axiAvatarPoseAt(5.5 * 0.94).blinkScaleY;
      final opening = axiAvatarPoseAt(5.5 * 0.98).blinkScaleY;
      expect(closing, lessThan(1.0));
      expect(closing, greaterThan(0.1));
      expect(opening, lessThan(1.0));
      expect(opening, greaterThan(0.1));
    });

    test('the cycle repeats every 5.5s', () {
      expect(axiAvatarPoseAt(5.5 * 0.96 + 5.5).blinkScaleY, closeTo(0.1, 1e-9));
      expect(axiAvatarPoseAt(5.5 * 0.96 + 11.0).blinkScaleY, closeTo(0.1, 1e-9));
    });
  });

  group('gillFloat (4s, both ear and lung gills)', () {
    test('starts and ends at -2deg, reaches +2deg at half the cycle', () {
      expect(_deg(axiAvatarPoseAt(0).gillRotation), closeTo(-2, 1e-9));
      expect(_deg(axiAvatarPoseAt(2.0).gillRotation), closeTo(2, 1e-9));
      expect(_deg(axiAvatarPoseAt(4.0).gillRotation), closeTo(-2, 1e-9));
    });

    test('sweeps up in the first half and back down in the second', () {
      expect(axiAvatarPoseAt(1.0).gillRotation,
          greaterThan(axiAvatarPoseAt(0.5).gillRotation));
      expect(axiAvatarPoseAt(3.5).gillRotation,
          lessThan(axiAvatarPoseAt(3.0).gillRotation));
    });
  });

  group('heartbeat (2s, double thump)', () {
    test('hits both systoles: 1.18 at 9% and 1.12 at 24%', () {
      expect(axiAvatarPoseAt(2.0 * 0.09).heartScale, closeTo(1.18, 1e-9));
      expect(axiAvatarPoseAt(2.0 * 0.24).heartScale, closeTo(1.12, 1e-9));
    });

    test('rests at 1.0 at 0%, 18%, 30% and for the rest of the cycle', () {
      for (final f in [0.0, 0.18, 0.30, 0.5, 0.9, 1.0]) {
        expect(axiAvatarPoseAt(2.0 * f).heartScale, closeTo(1.0, 1e-9),
            reason: '$f');
      }
    });

    test('never shrinks below rest size', () {
      for (var t = 0.0; t < 2.0; t += 0.01) {
        expect(axiAvatarPoseAt(t).heartScale, greaterThanOrEqualTo(1.0));
      }
    });
  });

  group('tailWag (4.5s)', () {
    test('swings from -3deg through +7deg and back', () {
      expect(_deg(axiAvatarPoseAt(0).tailRotation), closeTo(-3, 1e-9));
      expect(_deg(axiAvatarPoseAt(2.25).tailRotation), closeTo(7, 1e-9));
      expect(_deg(axiAvatarPoseAt(4.5).tailRotation), closeTo(-3, 1e-9));
    });
  });

  group('mind aura + sparks', () {
    test('the aura breathes between 0.22 and 0.5 on a 2.6s cycle', () {
      expect(axiAvatarPoseAt(0).mindAuraOpacity, closeTo(0.22, 1e-9));
      expect(axiAvatarPoseAt(1.3).mindAuraOpacity, closeTo(0.5, 1e-9));
      expect(axiAvatarPoseAt(2.6).mindAuraOpacity, closeTo(0.22, 1e-9));
    });

    test('sparks brighten, rise and grow at half the 2s cycle', () {
      final low = axiAvatarPoseAt(0);
      final high = axiAvatarPoseAt(1.0);
      expect(low.mindSparkOpacity, closeTo(0.35, 1e-9));
      expect(low.mindSparkScale, closeTo(0.85, 1e-9));
      expect(low.mindSparkOffsetY, closeTo(0.0, 1e-9));
      expect(high.mindSparkOpacity, closeTo(1.0, 1e-9));
      expect(high.mindSparkScale, closeTo(1.1, 1e-9));
      expect(high.mindSparkOffsetY, closeTo(-1.0, 1e-9));
    });
  });

  group('reduced motion', () {
    test('freezes every organ at the SVG\'s own static attributes', () {
      const rest = kAxiAvatarRestPose;
      expect(rest.blinkScaleY, 1.0);
      expect(rest.gillRotation, 0.0);
      expect(rest.heartScale, 1.0);
      expect(rest.tailRotation, 0.0);
      // The aura element carries opacity="0.4"; with `animation:none` that
      // attribute is what shows.
      expect(rest.mindAuraOpacity, 0.4);
      expect(rest.mindSparkOpacity, 1.0);
      expect(rest.mindSparkScale, 1.0);
      expect(rest.mindSparkOffsetY, 0.0);
    });
  });

  group('master loop', () {
    test('is a whole multiple of every keyframe duration, so it seams', () {
      final ms = kAxiAvatarLoop.inMilliseconds;
      for (final period in [5500, 4000, 2000, 4500, 2600]) {
        expect(ms % period, 0, reason: 'loop must contain $period ms exactly');
      }
    });

    test('the pose at the loop boundary equals the pose at zero', () {
      final start = axiAvatarPoseAt(0);
      final end = axiAvatarPoseAt(kAxiAvatarLoop.inMilliseconds / 1000);
      expect(end.blinkScaleY, closeTo(start.blinkScaleY, 1e-9));
      expect(end.gillRotation, closeTo(start.gillRotation, 1e-9));
      expect(end.heartScale, closeTo(start.heartScale, 1e-9));
      expect(end.tailRotation, closeTo(start.tailRotation, 1e-9));
      expect(end.mindAuraOpacity, closeTo(start.mindAuraOpacity, 1e-9));
      expect(end.mindSparkOpacity, closeTo(start.mindSparkOpacity, 1e-9));
    });
  });
}
