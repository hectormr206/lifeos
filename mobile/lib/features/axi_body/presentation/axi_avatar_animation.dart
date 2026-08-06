/// The idle-motion math for Axi's animated body, ported 1:1 from the CSS
/// keyframes that used to run inside a WebView (the deleted
/// `assets/axi/axi_avatar.html`; the original still lives on the laptop in
/// axi/src/axi/templates/dashboard.html ("Axi living avatar")).
///
/// Every timing, easing and value below is the original's:
///
/// ```css
/// @keyframes blink     { 0%,92%,100%{scaleY(1)} 96%{scaleY(0.1)} }        5.5s
/// @keyframes gillFloat { 0%,100%{rotate(-2deg)} 50%{rotate(2deg)} }       4.0s
/// @keyframes heartbeat { 0%,18%,30%,100%{scale(1)} 9%{1.18} 24%{1.12} }   2.0s
/// @keyframes tailWag   { 0%,100%{rotate(-3deg)} 50%{rotate(7deg)} }       4.5s
/// @keyframes mindPulse { 0%,100%{opacity:.22} 50%{opacity:.5} }           2.6s
/// @keyframes mindSpark { 0%,100%{.35/y0/s.85} 50%{1/y-1/s1.1} }           2.0s
/// ```
///
/// All of them are `ease-in-out infinite`, i.e. CSS
/// `cubic-bezier(0.42, 0, 0.58, 1)`; see [_ease].
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// CSS `ease-in-out` — `cubic-bezier(0.42, 0, 0.58, 1)` — solved exactly.
///
/// Flutter's own [Curves.easeInOut] is the same bezier, but its
/// [Cubic.transformInternal] locates `t` with a binary search bounded at
/// 1e-3, which leaves the KEYFRAME STOPS off by ~6e-7 (a lid that should read
/// exactly 0.1 comes back 0.1000006). That is invisible on screen but it
/// makes the pose non-deterministic to assert. Newton–Raphson with a
/// bisection fallback converges to ~1e-12, so every keyframe stop is exact.
double _ease(double t) {
  if (t <= 0.0) return 0.0;
  if (t >= 1.0) return 1.0;

  // Polynomial coefficients of the bezier's x(u) and y(u), u in [0, 1].
  const cx = 3 * 0.42, bx = 3 * (0.58 - 0.42) - cx, ax = 1 - cx - bx;
  const cy = 3 * 0.0, by = 3 * (1.0 - 0.0) - cy, ay = 1 - cy - by;
  double x(double u) => ((ax * u + bx) * u + cx) * u;
  double dx(double u) => (3 * ax * u + 2 * bx) * u + cx;

  var u = t;
  for (var i = 0; i < 8; i++) {
    final error = x(u) - t;
    if (error.abs() < 1e-12) break;
    final slope = dx(u);
    if (slope.abs() < 1e-12) break;
    u -= error / slope;
  }
  if (u < 0.0 || u > 1.0 || (x(u) - t).abs() > 1e-12) {
    var low = 0.0, high = 1.0;
    u = t;
    while (high - low > 1e-12) {
      if (x(u) < t) {
        low = u;
      } else {
        high = u;
      }
      u = (low + high) / 2;
    }
  }
  return ((ay * u + by) * u + cy) * u;
}

/// One full loop of the whole body: the least common multiple of every
/// keyframe duration (5500, 4000, 2000, 4500 and 2600 ms). Driving the
/// animation over exactly this period means the loop seams invisibly —
/// every organ is back at its 0% frame at the same instant.
const Duration kAxiAvatarLoop = Duration(milliseconds: 5148000);

double _radians(double degrees) => degrees * math.pi / 180;

/// Interpolates a CSS keyframe track. [stops] are `(fraction, value)` pairs in
/// ascending fraction order covering 0.0 and 1.0; [progress] is the cycle
/// position in `[0, 1)`.
double _track(List<(double, double)> stops, double progress) {
  for (var i = 0; i < stops.length - 1; i++) {
    final (from, fromValue) = stops[i];
    final (to, toValue) = stops[i + 1];
    if (progress <= to) {
      if (to == from) return toValue;
      final local = _ease((progress - from) / (to - from));
      return fromValue + (toValue - fromValue) * local;
    }
  }
  return stops.last.$2;
}

/// Cycle position of [seconds] within a [period]-second loop, in `[0, 1]`.
double _cycle(double seconds, double period) {
  final phase = seconds % period;
  return (phase < 0 ? phase + period : phase) / period;
}

/// Everything that moves on Axi's body at one instant. Immutable and
/// comparable so widget tests can assert "this pose did not change".
@immutable
class AxiAvatarPose {
  const AxiAvatarPose({
    required this.blinkScaleY,
    required this.gillRotation,
    required this.heartScale,
    required this.tailRotation,
    required this.mindAuraOpacity,
    required this.mindSparkOpacity,
    required this.mindSparkScale,
    required this.mindSparkOffsetY,
  });

  /// Vertical squash of both eyes — 1.0 open, 0.1 at the peak of a blink.
  final double blinkScaleY;

  /// Rotation (radians) of the ear and lung gills about the head, 32x40.
  final double gillRotation;

  /// Scale of the heart about 33.5x56.
  final double heartScale;

  /// Rotation (radians) of the tail about 41x59.
  final double tailRotation;

  /// Opacity of the teal aura over the head.
  final double mindAuraOpacity;

  /// Opacity, scale (about each spark's own centre) and vertical offset (in
  /// viewBox units) of the three thought sparks.
  final double mindSparkOpacity;
  final double mindSparkScale;
  final double mindSparkOffsetY;

  @override
  bool operator ==(Object other) =>
      other is AxiAvatarPose &&
      other.blinkScaleY == blinkScaleY &&
      other.gillRotation == gillRotation &&
      other.heartScale == heartScale &&
      other.tailRotation == tailRotation &&
      other.mindAuraOpacity == mindAuraOpacity &&
      other.mindSparkOpacity == mindSparkOpacity &&
      other.mindSparkScale == mindSparkScale &&
      other.mindSparkOffsetY == mindSparkOffsetY;

  @override
  int get hashCode => Object.hash(blinkScaleY, gillRotation, heartScale,
      tailRotation, mindAuraOpacity, mindSparkOpacity, mindSparkScale,
      mindSparkOffsetY);

  @override
  String toString() => 'AxiAvatarPose(blink: $blinkScaleY, gill: $gillRotation, '
      'heart: $heartScale, tail: $tailRotation, aura: $mindAuraOpacity, '
      'spark: $mindSparkOpacity/$mindSparkScale/$mindSparkOffsetY)';
}

/// The body at rest. This is what `@media (prefers-reduced-motion: reduce)`
/// produced in the asset: `animation: none`, so every element falls back to
/// its own static SVG attributes — including the aura's `opacity="0.4"`.
const AxiAvatarPose kAxiAvatarRestPose = AxiAvatarPose(
  blinkScaleY: 1.0,
  gillRotation: 0.0,
  heartScale: 1.0,
  tailRotation: 0.0,
  mindAuraOpacity: 0.4,
  mindSparkOpacity: 1.0,
  mindSparkScale: 1.0,
  mindSparkOffsetY: 0.0,
);

/// The pose [seconds] into the animation. Pure: the same input always paints
/// the same frame, which is what makes the goldens reproducible.
AxiAvatarPose axiAvatarPoseAt(double seconds) => AxiAvatarPose(
      blinkScaleY: _track(
        const [(0.0, 1.0), (0.92, 1.0), (0.96, 0.1), (1.0, 1.0)],
        _cycle(seconds, 5.5),
      ),
      gillRotation: _radians(_track(
        const [(0.0, -2.0), (0.5, 2.0), (1.0, -2.0)],
        _cycle(seconds, 4.0),
      )),
      heartScale: _track(
        const [
          (0.0, 1.0),
          (0.09, 1.18),
          (0.18, 1.0),
          (0.24, 1.12),
          (0.30, 1.0),
          (1.0, 1.0),
        ],
        _cycle(seconds, 2.0),
      ),
      tailRotation: _radians(_track(
        const [(0.0, -3.0), (0.5, 7.0), (1.0, -3.0)],
        _cycle(seconds, 4.5),
      )),
      mindAuraOpacity: _track(
        const [(0.0, 0.22), (0.5, 0.5), (1.0, 0.22)],
        _cycle(seconds, 2.6),
      ),
      mindSparkOpacity: _track(
        const [(0.0, 0.35), (0.5, 1.0), (1.0, 0.35)],
        _cycle(seconds, 2.0),
      ),
      mindSparkScale: _track(
        const [(0.0, 0.85), (0.5, 1.1), (1.0, 0.85)],
        _cycle(seconds, 2.0),
      ),
      mindSparkOffsetY: _track(
        const [(0.0, 0.0), (0.5, -1.0), (1.0, 0.0)],
        _cycle(seconds, 2.0),
      ),
    );
