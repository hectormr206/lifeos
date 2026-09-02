// A kind that reaches the 3D must reach it with a colour and a name.
//
// Generic `entity` nodes (places, medications, things) now enter the scene:
// without an entry here every one of them would draw in the fallback grey and
// its detail chip would read the raw English key "entity".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/domain_labels.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_palette.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_payload.dart';

void main() {
  group('brain3dColorFor', () {
    test('every kind the 3D loads has its own colour', () {
      for (final kind in kBrain3dKinds) {
        expect(
          brain3dColorFor(kind: kind),
          isNot(kDefaultNodeColor),
          reason: '$kind would render as an unnamed grey dot',
        );
      }
    });

    test('entity does not borrow another kind\'s colour', () {
      final entity = brain3dColorFor(kind: 'entity');
      for (final kind in ['fact', 'person', 'event', 'conversation']) {
        expect(entity, isNot(brain3dColorFor(kind: kind)));
      }
    });

    test('domain still wins over kind', () {
      expect(
        brain3dColorFor(domain: 'health', kind: 'entity'),
        brain3dColorFor(domain: 'health'),
      );
    });

    test('an unknown kind is still grey, not a guess', () {
      expect(brain3dColorFor(kind: 'no-such-kind'), kDefaultNodeColor);
    });
  });

  test('the detail chip names an entity in Spanish', () {
    // The panel renders `domainLabel(node.kind)`; without this the chip on
    // "Monterrey" would read "entity".
    expect(domainLabel('entity'), 'Cosa');
  });
}
