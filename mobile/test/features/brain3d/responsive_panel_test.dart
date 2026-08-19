// The same screen, shaped for the window it is in.
//
// "Necesitamos que sea para Android y para Linux el mismo." It already is —
// there is not one platform branch in the whole feature. What differed was the
// WINDOW: the same code in a 1440x3120 phone and in a 2560x1430 laptop.
//
// The desktop original puts the details in a column beside the graph and uses
// the width. Dropping a phone's bottom sheet into a laptop window wastes two
// thirds of the screen and looks like a port rather than the app.
//
// Same features, same code, shape chosen by width — which is what
// "multiplatform" has to mean when the platforms have different screens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/brain3d/presentation/brain3d_layout.dart';

void main() {
  test('a phone gets the panel at the bottom', () {
    expect(brain3dPanelPlacement(const Size(1440, 3120) / 3),
        Brain3dPanelPlacement.bottom);
  });

  test('a laptop window gets it beside the graph', () {
    expect(brain3dPanelPlacement(const Size(2560, 1430) / 2),
        Brain3dPanelPlacement.side);
  });

  test('a narrow desktop window still gets the bottom sheet', () {
    // Half a laptop screen is phone-shaped. The rule is the WIDTH available,
    // never the operating system — a resized window must not keep a layout
    // that no longer fits it.
    expect(brain3dPanelPlacement(const Size(600, 800)),
        Brain3dPanelPlacement.bottom);
  });

  test('a tablet held wide gets the side panel', () {
    expect(brain3dPanelPlacement(const Size(1100, 800)),
        Brain3dPanelPlacement.side);
  });

  test('the threshold is the same number on every platform', () {
    // One constant, so "the same on Android and Linux" is a fact about the
    // code rather than a promise in a commit message.
    expect(kBrain3dSidePanelWidth, 900);
  });
}
