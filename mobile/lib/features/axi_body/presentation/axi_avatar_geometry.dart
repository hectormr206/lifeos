/// Axi's body, as geometry.
///
/// Every path here is transcribed from the SVG that used to be rendered by a
/// WebView (the deleted `assets/axi/axi_avatar.html`; the original is on the
/// laptop in axi/src/axi/templates/dashboard.html ("Axi living avatar")), in that SVG's own `0 0 64 80` viewBox coordinates. The painter draws these shapes and the widget
/// hit-tests them, so the picture and the touch targets cannot drift apart.
library;

import 'dart:typed_data';
import 'dart:ui' show Offset, Path, PathOperation, Rect, Size;

import 'dart:math' as math;

/// The SVG's `viewBox="0 0 64 80"`.
const Size kAxiAvatarViewBox = Size(64, 80);

/// The SVG's intrinsic `width="220" height="275"` — same aspect ratio, so the
/// avatar always scales uniformly.
const Size kAxiAvatarIntrinsicSize = Size(220, 275);

/// A 2D affine transform as the column-major 4x4 matrix `Path.transform` wants.
Float64List _affine(double a, double b, double c, double d, double tx,
        double ty) =>
    Float64List.fromList(<double>[
      a, b, 0, 0, //
      c, d, 0, 0, //
      0, 0, 1, 0, //
      tx, ty, 0, 1, //
    ]);

/// SVG `transform="translate(tx,ty) rotate(deg) scale(s)"`.
Float64List _translateRotateScale(double tx, double ty, double deg, double s) {
  final r = deg * math.pi / 180;
  return _affine(s * math.cos(r), s * math.sin(r), -s * math.sin(r),
      s * math.cos(r), tx, ty);
}

/// SVG `transform="rotate(deg px py)"`.
Float64List rotateAbout(double deg, double px, double py) {
  final r = deg * math.pi / 180;
  final (cos, sin) = (math.cos(r), math.sin(r));
  return _affine(cos, sin, -sin, cos, px - px * cos + py * sin,
      py - px * sin - py * cos);
}

Path _ellipse(double cx, double cy, double rx, double ry) =>
    Path()..addOval(Rect.fromCenter(
        center: Offset(cx, cy), width: rx * 2, height: ry * 2));

Path _union(Path a, Path b) => Path.combine(PathOperation.union, a, b);

// ── The gill, the SVG's reusable `<g id="axi-gill">` ────────────────────────
// A pink ellipse with a teal tip; every ear/lung filament is one of these
// under a translate+rotate+scale.

/// The pink filament of a gill, in the gill's own local coordinates.
Path _gillBody() => _ellipse(0, -8.5, 3.8, 10.6);

/// The teal tip: `M0 -16.2 Q-3.2 -12 -2.6 -7.2 Q0 -8.6 2.6 -7.2 Q3.2 -12 0 -16.2 Z`
Path gillTipPath() => Path()
  ..moveTo(0, -16.2)
  ..quadraticBezierTo(-3.2, -12, -2.6, -7.2)
  ..quadraticBezierTo(0, -8.6, 2.6, -7.2)
  ..quadraticBezierTo(3.2, -12, 0, -16.2)
  ..close();

/// `<use href="#axi-gill" transform="translate(tx,ty) rotate(deg) scale(s)"/>`
/// placements, in document order.
const List<(double, double, double, double)> kAxiEarGills = [
  (23, 32, -56, 0.94),
  (20, 37, -79, 0.95),
  (41, 32, 56, 0.94),
  (44, 37, 79, 0.95),
];
const List<(double, double, double, double)> kAxiLungGills = [
  (22, 43, -95, 0.9),
  (42, 43, 95, 0.9),
];

/// The gill placement's matrix, so the painter can reuse it verbatim.
Float64List axiGillTransform((double, double, double, double) gill) =>
    _translateRotateScale(gill.$1, gill.$2, gill.$3, gill.$4);

Path _gillsFor(List<(double, double, double, double)> gills) {
  var path = Path();
  for (final gill in gills) {
    path = _union(path, _gillBody().transform(axiGillTransform(gill)));
  }
  return path;
}

// ── Body parts shared by the painter and the hit test ───────────────────────

/// The wagging tail's outline (the tail is decorative — it opens nothing).
Path axiTailPath() => Path()
  ..moveTo(40, 57)
  ..quadraticBezierTo(52, 54, 57, 63)
  ..quadraticBezierTo(52, 70, 45, 65)
  ..quadraticBezierTo(41, 62, 40, 57)
  ..close();

/// The smile, as the SVG strokes it: `M26 43 Q32 48 38 43`.
Path axiMouthPath() => Path()
  ..moveTo(26, 43)
  ..quadraticBezierTo(32, 48, 38, 43);

/// The heart: two lobes and the point below them.
Path axiHeartPath() => _union(
      _union(_ellipse(32.2, 55, 1.45, 1.45), _ellipse(34.8, 55, 1.45, 1.45)),
      Path()
        ..moveTo(30.85, 55.6)
        ..quadraticBezierTo(33.5, 60.5, 36.15, 55.6)
        ..close(),
    );

/// The two hands, each an ellipse under its own `rotate(deg cx cy)`.
Path axiHandsPath() => _union(
      _ellipse(21, 53, 3, 4.3).transform(rotateAbout(32, 22, 53)),
      _ellipse(43, 53, 3, 4.3).transform(rotateAbout(-32, 42, 53)),
    );

Path axiFeetPath() =>
    _union(_ellipse(25.5, 67.5, 3.8, 3.3), _ellipse(38.5, 67.5, 3.8, 3.3));

Path axiEyesPath() =>
    _union(_ellipse(26, 38, 2.6, 2.6), _ellipse(38, 38, 2.6, 2.6));

/// The dashed immune ring, as a band around its `stroke-width="1.4"` path.
/// The SVG sets `pointer-events:stroke`; the band ignores the dash gaps so a
/// finger between two dashes still reaches it.
Path _immuneBand() => Path.combine(
      PathOperation.difference,
      _ellipse(32, 57, 14.5 + 0.7, 14 + 0.7),
      _ellipse(32, 57, 14.5 - 0.7, 14 - 0.7),
    );

// ── Hit testing ────────────────────────────────────────────────────────────

/// One entry of the avatar's hit stack. A null [organ] is an opaque part with
/// no action (the face, the body, the tail): in the browser it was the topmost
/// element under the finger and swallowed the tap, and it still does.
class AxiOrganRegion {
  const AxiOrganRegion(this.organ, this.path);

  /// The key the old `Axi` JavaScript channel would have posted, or null.
  final String? organ;
  final Path path;
}

/// The avatar's stack, TOPMOST FIRST — the reverse of the SVG's paint order,
/// which is how a browser resolves a click.
final List<AxiOrganRegion> kAxiOrganHitOrder = List.unmodifiable([
  // The `<ellipse ... fill-opacity="0">` catchers are invisible but clickable,
  // exactly as in the SVG.
  AxiOrganRegion('mind', _ellipse(32, 16, 13, 9)),
  AxiOrganRegion('heart', axiHeartPath()),
  // The SVG only strokes the smile (1 unit wide). We take the area the smile
  // encloses instead: the same place on the face, but a target a finger can
  // actually hit.
  AxiOrganRegion('mouth', axiMouthPath()..close()),
  AxiOrganRegion('smell', _ellipse(32, 41, 2.6, 1.6)),
  AxiOrganRegion('eyes', axiEyesPath()),
  AxiOrganRegion('brain', _ellipse(32, 30.5, 7, 3.8)),
  AxiOrganRegion(null, _ellipse(32, 38, 15.5, 13.5)), // face
  AxiOrganRegion('memory', _ellipse(32, 59, 7.6, 7.8)),
  AxiOrganRegion(null, _ellipse(32, 57, 12.5, 12)), // body
  AxiOrganRegion('immune', _immuneBand()),
  AxiOrganRegion('feet', axiFeetPath()),
  AxiOrganRegion('hands', axiHandsPath()),
  AxiOrganRegion(null, axiTailPath()), // decorative
  AxiOrganRegion('lungs', _gillsFor(kAxiLungGills)),
  AxiOrganRegion('ears', _gillsFor(kAxiEarGills)),
]);

/// Maps a point local to a [size]-sized avatar box into viewBox coordinates.
/// Mirrors how the painter places the viewBox: uniform scale, centred — the
/// SVG's default `preserveAspectRatio`.
Offset axiViewBoxPoint(Offset local, Size size) {
  final scale = math.min(
      size.width / kAxiAvatarViewBox.width, size.height / kAxiAvatarViewBox.height);
  if (scale <= 0) return Offset.zero;
  return Offset(
    (local.dx - (size.width - kAxiAvatarViewBox.width * scale) / 2) / scale,
    (local.dy - (size.height - kAxiAvatarViewBox.height * scale) / 2) / scale,
  );
}

/// The organ key at [point] (viewBox coordinates), or null where the tap hits
/// nothing actionable — bare canvas, or an opaque part that covers an organ.
String? axiOrganAtViewBox(Offset point) {
  for (final region in kAxiOrganHitOrder) {
    if (region.path.contains(point)) return region.organ;
  }
  return null;
}
