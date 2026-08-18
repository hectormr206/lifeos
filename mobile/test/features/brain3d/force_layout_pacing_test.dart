// How the 3D graph is allowed to move while the user is watching.
//
// Reported as "se aloca y empieza a mover muy rápido, y ya después se queda
// quieto". Measured before changing anything:
//
//   energía ≈ 11.97 en el primer paso y ≈ 11.64 en el doceavo — the movement
//   cap is hit on EVERY early step, so every node jumps the maximum distance
//   every frame;
//   converge en 399 pasos, i.e. it stops on the step LIMIT, not on rest;
//   the ticker runs one step per FRAME, so the whole thing lasts 3.33 s on a
//   120 Hz Pixel and 6.65 s on a 60 Hz screen.
//
// Two separate defects behind one symptom: the violent phase is shown at all,
// and its duration is decided by the display's refresh rate.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/domain/force_layout.dart';

ForceLayout _layout({int warmupSteps = kForceLayoutWarmupSteps}) => ForceLayout(
      nodeIds: [for (var i = 0; i < 30; i++) 'n$i'],
      edges: [for (var i = 1; i < 30; i++) ('n${i - 1}', 'n$i')],
      seed: 7,
      warmupSteps: warmupSteps,
    );

void main() {
  group('the violent phase is not shown', () {
    test('a warmed layout starts far calmer than a raw one', () {
      final raw = _layout(warmupSteps: 0)..step();
      final warmed = _layout()..step();

      expect(
        warmed.energy,
        lessThan(raw.energy / 2),
        reason: 'the first frame the user sees must be a settling, not a jump',
      );
    });

    test('warming up still reaches a settled layout', () {
      // The calm start must not be bought by stopping early: a layout that
      // never converges leaves the graph a tangle no matter how gently it got
      // there.
      final warmed = _layout()..settle();

      expect(warmed.done, isTrue);
    });

    test('warming up does not collapse the graph onto a point', () {
      // The cheapest way to make energy small is to put every node in the same
      // place. Asserting the shape survives keeps that from passing.
      final warmed = _layout()..settle();
      final positions = warmed.positions.values.toList();

      var maxSeparation = 0.0;
      for (final a in positions) {
        for (final b in positions) {
          final d = a.distanceTo(b);
          if (d > maxSeparation) maxSeparation = d;
        }
      }
      expect(maxSeparation, greaterThan(1.0));
    });
  });

  test('the first painted frame is already settled', () {
    // Reported twice: "se aloca y empieza a mover muy rápido", then "todo
    // vibra". Nothing is allowed to move once the screen is up.
    final layout = _layout();

    expect(layout.done, isTrue,
        reason: 'the ticker must have nothing left to animate');
  });

  group('the unfolding lasts the same on any screen', () {
    test('advancing by time runs steps proportional to the time', () {
      final fast = _layout();
      final slow = _layout();

      // 120 Hz: sixty short frames. 60 Hz: thirty long ones. Same second.
      final start = fast.stepsTaken;
      for (var i = 0; i < 60; i++) {
        fast.advance(const Duration(milliseconds: 8));
      }
      for (var i = 0; i < 30; i++) {
        slow.advance(const Duration(milliseconds: 16));
      }

      expect(fast.stepsTaken - start, closeTo(slow.stepsTaken - start, 4),
          reason: 'a 120 Hz phone must not finish in half the time');
    });

    test('one long frame does not teleport the graph', () {
      // A dropped frame, a garbage collection, or the app returning from the
      // background hands us a huge delta. Replaying it in full would make the
      // graph jump exactly the way this bug looked.
      final layout = _layout();
      final before = layout.stepsTaken;

      layout.advance(const Duration(seconds: 30));

      // The INCREMENT is the rule; `stepsTaken` also counts the warm-up.
      expect(
        layout.stepsTaken - before,
        lessThanOrEqualTo(kForceLayoutMaxStepsPerFrame),
      );
    });

    test('a settled layout stops consuming time', () {
      final layout = _layout()..settle();
      final before = layout.stepsTaken;

      layout.advance(const Duration(milliseconds: 16));

      expect(layout.stepsTaken, before);
    });
  });
}
