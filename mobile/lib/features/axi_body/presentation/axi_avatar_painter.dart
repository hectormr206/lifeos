/// Draws Axi's living body with Flutter's own canvas.
///
/// This is a transcription of the SVG that used to be rendered inside a
/// WebView (the deleted `assets/axi/axi_avatar.html`; original on the laptop
/// in axi/src/axi/templates/dashboard.html ("Axi living avatar")): same viewBox, same paint order,
/// same fills, strokes and stroke widths, same organ groups. The motion comes
/// from [AxiAvatarPose], which ports the asset's CSS keyframes.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'axi_avatar_animation.dart';
import 'axi_avatar_geometry.dart';

// The palette, verbatim from the SVG.
const _pink = Color(0xFFFE8FAF);
const _ink = Color(0xFF241019);
const _teal = Color(0xFF00D4AA);
const _tealLight = Color(0xFF7FF0E0);
const _blush = Color(0xFFFFC2D6);
const _rose = Color(0xFFFF6B9D);
const _hotPink = Color(0xFFFF4D88);
const _pupil = Color(0xFF14131F);
const _stem = Color(0xFFD94F86);

Paint _fill(Color color, {double opacity = 1.0}) => Paint()
  ..style = PaintingStyle.fill
  ..color = color.withValues(alpha: color.a * opacity)
  ..isAntiAlias = true;

Paint _stroke(Color color, double width,
        {double opacity = 1.0,
        StrokeCap cap = StrokeCap.butt,
        StrokeJoin join = StrokeJoin.miter}) =>
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = cap
      ..strokeJoin = join
      ..color = color.withValues(alpha: color.a * opacity)
      ..isAntiAlias = true;

Rect _oval(double cx, double cy, double rx, double ry) =>
    Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);

/// Rebuilds [source] as the visible runs of a `stroke-dasharray: dash gap`.
Path _dashed(Path source, double dash, double gap) {
  final out = Path();
  for (final metric in source.computeMetrics()) {
    var distance = 0.0;
    var visible = true;
    while (distance < metric.length) {
      final end = math.min(distance + (visible ? dash : gap), metric.length);
      if (visible) out.addPath(metric.extractPath(distance, end), Offset.zero);
      distance = end;
      visible = !visible;
    }
  }
  return out;
}

/// Runs [draw] inside `translate(px,py) rotate(r) scale(sx,sy) translate(-px,-py)`.
void _about(Canvas canvas, double px, double py,
    {double rotation = 0, double scaleX = 1, double scaleY = 1,
    required VoidCallback draw}) {
  canvas
    ..save()
    ..translate(px, py)
    ..rotate(rotation)
    ..scale(scaleX, scaleY)
    ..translate(-px, -py);
  draw();
  canvas.restore();
}

class AxiAvatarPainter extends CustomPainter {
  const AxiAvatarPainter({required this.elapsedSeconds, required this.pose});

  /// Time since the animation started. Held so tests can prove the loop is
  /// advancing; the picture itself depends only on [pose].
  final double elapsedSeconds;
  final AxiAvatarPose pose;

  @override
  void paint(Canvas canvas, Size size) {
    // `viewBox="0 0 64 80"` with the SVG's default `preserveAspectRatio`:
    // uniform scale, centred.
    final scale = math.min(size.width / kAxiAvatarViewBox.width,
        size.height / kAxiAvatarViewBox.height);
    canvas
      ..save()
      ..translate((size.width - kAxiAvatarViewBox.width * scale) / 2,
          (size.height - kAxiAvatarViewBox.height * scale) / 2)
      ..scale(scale);

    // Document order == paint order. Bottom of the stack first.
    _paintGills(canvas, kAxiEarGills);
    _paintGills(canvas, kAxiLungGills);
    _paintTail(canvas);
    _paintHands(canvas);
    _paintFeet(canvas);
    _paintImmuneRing(canvas);
    _paintBody(canvas);
    _paintMemory(canvas);
    _paintFace(canvas);
    _paintBrain(canvas);
    _paintCheeks(canvas);
    _paintEyes(canvas);
    _paintNose(canvas);
    _paintMouth(canvas);
    _paintHeart(canvas);
    _paintMind(canvas);

    canvas.restore();
  }

  /// Ears and lungs share `gillFloat`, rotating about the head at 32x40.
  void _paintGills(Canvas canvas, List<(double, double, double, double)> gills) {
    _about(canvas, 32, 40, rotation: pose.gillRotation, draw: () {
      for (final gill in gills) {
        final matrix = axiGillTransform(gill);
        final body = (Path()..addOval(_oval(0, -8.5, 3.8, 10.6)))
            .transform(matrix);
        final tip = gillTipPath().transform(matrix);
        // A `<use>`'s scale also scales its strokes, exactly as here.
        final s = gill.$4;
        canvas
          ..drawPath(body, _fill(_pink))
          ..drawPath(body, _stroke(_ink, 0.9 * s))
          ..drawPath(tip, _fill(_teal))
          ..drawPath(tip, _stroke(_ink, 0.42 * s, join: StrokeJoin.round));
      }
    });
  }

  void _paintTail(Canvas canvas) {
    _about(canvas, 41, 59, rotation: pose.tailRotation, draw: () {
      final tail = axiTailPath();
      canvas
        ..drawPath(tail, _fill(_pink))
        ..drawPath(tail, _stroke(_ink, 0.9, join: StrokeJoin.round))
        ..drawPath(
          Path()
            ..moveTo(44, 58)
            ..quadraticBezierTo(50, 58, 55, 63),
          _stroke(_ink, 0.45, opacity: 0.5, cap: StrokeCap.round),
        )
        ..drawPath(
          Path()
            ..moveTo(44, 62)
            ..quadraticBezierTo(49, 64, 55, 63),
          _stroke(_ink, 0.45, opacity: 0.4, cap: StrokeCap.round),
        );
    });
  }

  void _paintHands(Canvas canvas) {
    for (final (cx, cy, deg, px) in const [(21.0, 53.0, 32.0, 22.0), (43.0, 53.0, -32.0, 42.0)]) {
      final hand = (Path()..addOval(_oval(cx, cy, 3, 4.3)))
          .transform(rotateAbout(deg, px, 53));
      canvas
        ..drawPath(hand, _fill(_pink))
        ..drawPath(hand, _stroke(_ink, 0.9));
    }
  }

  void _paintFeet(Canvas canvas) {
    for (final cx in const [25.5, 38.5]) {
      final foot = _oval(cx, 67.5, 3.8, 3.3);
      canvas
        ..drawOval(foot, _fill(_pink))
        ..drawOval(foot, _stroke(_ink, 0.9));
    }
  }

  /// `stroke-dasharray="2.2 2.6"`, `opacity="0.35"`.
  void _paintImmuneRing(Canvas canvas) {
    canvas.drawPath(
      _dashed(Path()..addOval(_oval(32, 57, 14.5, 14)), 2.2, 2.6),
      _stroke(_teal, 1.4, opacity: 0.35),
    );
  }

  void _paintBody(Canvas canvas) {
    final body = _oval(32, 57, 12.5, 12);
    canvas
      ..drawOval(body, _fill(_pink))
      ..drawOval(body, _stroke(_ink, 0.9));
  }

  /// The belly-core: what Axi remembers, ringed by its layers.
  void _paintMemory(Canvas canvas) {
    canvas
      ..drawOval(_oval(32, 59, 7.6, 7.8), _fill(_blush, opacity: 0.7))
      ..drawOval(_oval(32, 59, 5.4, 5.6), _stroke(_rose, 0.4, opacity: 0.3))
      ..drawOval(_oval(32, 59, 3.3, 3.5), _stroke(_rose, 0.4, opacity: 0.35));
  }

  void _paintFace(Canvas canvas) {
    final face = _oval(32, 38, 15.5, 13.5);
    canvas
      ..drawOval(face, _fill(_pink))
      ..drawOval(face, _stroke(_ink, 0.9));
  }

  void _paintBrain(Canvas canvas) {
    canvas
      ..drawOval(_oval(32, 30.3, 2.7, 2), _fill(_blush))
      ..drawOval(_oval(32, 30.3, 2.7, 2), _stroke(_stem, 0.35))
      ..drawPath(
        Path()
          ..moveTo(29.8, 30.3)
          ..quadraticBezierTo(31, 29.4, 32, 30.3)
          ..quadraticBezierTo(33, 31.2, 34.2, 30.3),
        _stroke(_stem, 0.35, opacity: 0.85, cap: StrokeCap.round),
      )
      ..drawLine(const Offset(32, 28.5), const Offset(32, 32.1),
          _stroke(_stem, 0.3, opacity: 0.5));
  }

  void _paintCheeks(Canvas canvas) {
    for (final cx in const [21.5, 42.5]) {
      canvas.drawCircle(Offset(cx, 42), 2.2, _fill(_hotPink, opacity: 0.5));
    }
  }

  /// Both eyes blink together, each squashing about its own centre.
  void _paintEyes(Canvas canvas) {
    for (final cx in const [26.0, 38.0]) {
      _about(canvas, cx, 38, scaleY: pose.blinkScaleY, draw: () {
        canvas
          ..drawCircle(Offset(cx, 38), 2.6, _fill(_pupil))
          ..drawCircle(Offset(cx + 0.9, 37.2), 0.9, _fill(Colors.white));
      });
    }
  }

  void _paintNose(Canvas canvas) {
    for (final cx in const [31.1, 32.9]) {
      canvas.drawCircle(Offset(cx, 41), 0.42, _fill(_pupil, opacity: 0.55));
    }
  }

  void _paintMouth(Canvas canvas) {
    canvas.drawPath(
      axiMouthPath(),
      _stroke(_pupil, 1, cap: StrokeCap.round),
    );
  }

  void _paintHeart(Canvas canvas) {
    _about(canvas, 33.5, 56,
        scaleX: pose.heartScale,
        scaleY: pose.heartScale, draw: () {
      canvas.drawPath(axiHeartPath(), _fill(_hotPink));
    });
  }

  /// The autonomous mind: a soft teal aura and three thought sparks.
  void _paintMind(Canvas canvas) {
    canvas.drawOval(
      _oval(32, 19, 11, 4.5),
      _fill(_teal, opacity: pose.mindAuraOpacity)
        // CSS `filter: blur(2.5px)` in the SVG's user space.
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    for (final (cx, cy, r, color) in const [
      (25.0, 16.0, 1.1, _tealLight),
      (32.0, 12.5, 1.5, _teal),
      (39.0, 16.0, 1.1, _tealLight),
    ]) {
      canvas.drawCircle(
        Offset(cx, cy + pose.mindSparkOffsetY),
        r * pose.mindSparkScale,
        _fill(color, opacity: pose.mindSparkOpacity),
      );
    }
  }

  @override
  bool shouldRepaint(AxiAvatarPainter oldDelegate) =>
      oldDelegate.pose != pose;
}
