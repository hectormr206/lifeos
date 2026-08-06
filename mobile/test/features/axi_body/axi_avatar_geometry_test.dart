// Proves the NATIVE avatar's organ hit-testing reproduces what the deleted
// SVG asset did, including its stacking order: the opaque
// face, body and tail sit ABOVE some organ groups and therefore swallow taps
// that land on them, exactly as the browser's topmost-element hit test did.
//
// All coordinates are in the SVG's own 64x80 viewBox space.
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_geometry.dart';

void main() {
  test('the viewBox matches the SVG (64x80) and its intrinsic 220x275 box', () {
    expect(kAxiAvatarViewBox, const Size(64, 80));
    expect(kAxiAvatarIntrinsicSize, const Size(220, 275));
    // Uniform scale: the intrinsic box has the viewBox's exact aspect ratio.
    expect(kAxiAvatarIntrinsicSize.width / kAxiAvatarViewBox.width,
        closeTo(kAxiAvatarIntrinsicSize.height / kAxiAvatarViewBox.height, 1e-9));
  });

  group('organ hit regions', () {
    test('the thinking sparks and their aura are the autonomous mind', () {
      expect(axiOrganAtViewBox(const Offset(32, 13)), 'mind');
      expect(axiOrganAtViewBox(const Offset(32, 20)), 'mind');
    });

    test('the little brain sits on top of the head', () {
      expect(axiOrganAtViewBox(const Offset(32, 30.3)), 'brain');
    });

    test('both eyes are tappable', () {
      expect(axiOrganAtViewBox(const Offset(26, 38)), 'eyes');
      expect(axiOrganAtViewBox(const Offset(38, 38)), 'eyes');
    });

    test('nose and mouth are distinct targets', () {
      expect(axiOrganAtViewBox(const Offset(32, 41)), 'smell');
      expect(axiOrganAtViewBox(const Offset(32, 45)), 'mouth');
    });

    test('the heart beats above the memory belly', () {
      expect(axiOrganAtViewBox(const Offset(32, 55.5)), 'heart');
      expect(axiOrganAtViewBox(const Offset(32, 60)), 'memory');
    });

    test('the dashed immune ring is reachable outside the body', () {
      expect(axiOrganAtViewBox(const Offset(46.5, 57)), 'immune');
    });

    test('hands and feet are reachable where the body does not cover them', () {
      expect(axiOrganAtViewBox(const Offset(20, 51)), 'hands');
      expect(axiOrganAtViewBox(const Offset(25.5, 67.5)), 'feet');
    });

    test('upper gills are ears, lower gills are lungs', () {
      expect(axiOrganAtViewBox(const Offset(17, 28)), 'ears');
      expect(axiOrganAtViewBox(const Offset(15, 43.5)), 'lungs');
      // The dashed immune ring passes OVER the feet, exactly as in the SVG.
      expect(axiOrganAtViewBox(const Offset(24, 68)), 'immune');
    });

    test('every organ key the map knows is reachable somewhere', () {
      final reachable = <String>{};
      for (var x = 0.0; x < 64; x += 0.25) {
        for (var y = 0.0; y < 80; y += 0.25) {
          final key = axiOrganAtViewBox(Offset(x, y));
          if (key != null) reachable.add(key);
        }
      }
      expect(
        reachable,
        containsAll(<String>[
          'mind', 'brain', 'eyes', 'smell', 'mouth', 'heart',
          'memory', 'immune', 'hands', 'feet', 'ears', 'lungs',
        ]),
      );
    });

    test('only organ keys the action map knows are ever emitted', () {
      for (var x = 0.0; x < 64; x += 0.5) {
        for (var y = 0.0; y < 80; y += 0.5) {
          final key = axiOrganAtViewBox(Offset(x, y));
          if (key != null) {
            expect(kAxiOrganHitOrder.map((r) => r.organ), contains(key));
          }
        }
      }
    });
  });

  group('opaque parts swallow taps, as they did in the browser', () {
    test('the face covers the inner ends of the gills', () {
      expect(axiOrganAtViewBox(const Offset(32, 38 - 6)), isNot('ears'));
    });

    test('the tail is decorative and resolves to no organ', () {
      expect(axiOrganAtViewBox(const Offset(50, 62)), isNull);
    });

    test('empty canvas resolves to no organ', () {
      expect(axiOrganAtViewBox(const Offset(2, 2)), isNull);
      expect(axiOrganAtViewBox(const Offset(60, 78)), isNull);
    });
  });
}
