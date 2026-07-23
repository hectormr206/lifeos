// Shared helpers for the golden/screenshot harness.
//
// These render the REAL screens to deterministic PNGs on the test host — no
// emulator, no on-device model, no network, no native plugins. Data + clock
// are fixed so the images are byte-stable across runs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

/// Fixed logical surface for every golden: a typical phone portrait viewport.
/// devicePixelRatio 2.0 keeps text crisp while keeping the PNG a sane size.
const Size kGoldenLogicalSize = Size(390, 844);
const double kGoldenDpr = 2.0;

/// Pins the test surface to [kGoldenLogicalSize] and resets it afterwards, so
/// each golden is captured at exactly the same resolution regardless of the
/// host's real screen.
void useGoldenSurface(WidgetTester tester) {
  tester.view.physicalSize = kGoldenLogicalSize * kGoldenDpr;
  tester.view.devicePixelRatio = kGoldenDpr;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// The brand (LifeOS) light theme with a real text font forced on, so golden
/// text is READABLE (see flutter_test_config.dart). Bare `Text` widgets inherit
/// this family through the ambient DefaultTextStyle, so even styles that only
/// set a colour pick up the real font.
ThemeData goldenTheme() {
  final base = lifeosLightTheme;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
    // The brand appBar title style sets no family; force the loaded real font
    // so the AppBar title renders as readable text and not a tofu box.
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle:
          base.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
    ),
  );
}
