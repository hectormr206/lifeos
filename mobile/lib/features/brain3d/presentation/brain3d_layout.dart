// Where the details panel goes.
//
// The feature has no platform branch and never should: what changes between a
// phone and a laptop is the WINDOW, not the operating system. A window can be
// resized, a tablet can be turned, and a desktop app can be half a screen wide
// — so the rule reads the width it actually has.
library;

import 'dart:ui';

/// Above this width the details sit beside the graph, as the desktop Cerebro
/// has always shown them; below it they slide up from the bottom.
///
/// One constant, so "the same on Android and Linux" is something the code says
/// rather than something a commit message promises.
const double kBrain3dSidePanelWidth = 900;

enum Brain3dPanelPlacement { bottom, side }

Brain3dPanelPlacement brain3dPanelPlacement(Size window) =>
    window.width >= kBrain3dSidePanelWidth
        ? Brain3dPanelPlacement.side
        : Brain3dPanelPlacement.bottom;
