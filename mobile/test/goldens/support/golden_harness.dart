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

/// Real light theme: bundled fonts are loaded by flutter_test_config.dart via
/// FontManifest.json, so no Roboto override is needed for readable goldens.
ThemeData goldenTheme() => lifeosLightTheme;

/// Real dark theme for future dark-mode snapshots.
ThemeData goldenDarkTheme() => lifeosDarkTheme;
