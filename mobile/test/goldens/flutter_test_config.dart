// Golden-test bootstrap (applies to every test under test/goldens/).
//
// flutter_test ships NO real Latin text font, so by default golden PNGs render
// text as opaque boxes — useless for a human to inspect. Here we load a real
// sans-serif under the family name `Roboto`, which the golden MaterialApps set
// as their default fontFamily. Result: the deliverable PNGs show READABLE text.
//
// The font is VENDORED under test/fonts/ rather than probed from the host.
// Golden output is byte-sensitive to font metrics, so scanning system paths
// made the PNGs reproduce only on machines that happened to resolve the same
// file: a laptop, the VPS, and the CI container each picked a different font
// (or none at all, falling back to boxed glyphs), and the same commit passed
// locally while failing CI with a ~28% pixel diff. Loading fixed bytes makes
// the goldens reproduce identically everywhere.
//
// Test-only: it never ships and touches no production code.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Vendored font files, resolved from the package root (`flutter test` runs
/// with the working directory set there). See test/fonts/LICENSE.
const _regularFont = 'test/fonts/DejaVuSans.ttf';
const _boldFont = 'test/fonts/DejaVuSans-Bold.ttf';

Future<void> _loadRealTextFont() async {
  final regular = File(_regularFont);
  final bold = File(_boldFont);
  if (!regular.existsSync() || !bold.existsSync()) {
    // Deliberately fatal: silently degrading to boxed glyphs is what let the
    // goldens diverge per machine in the first place.
    throw StateError(
      'Vendored golden fonts missing ($_regularFont, $_boldFont). '
      'Run `flutter test` from the mobile/ package root.',
    );
  }

  // Register under the family name the golden screens actually request so all
  // text (theme text styles default to `Roboto`) resolves to a real glyph.
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(regular.readAsBytesSync().buffer.asByteData()))
    ..addFont(Future.value(bold.readAsBytesSync().buffer.asByteData()));
  await loader.load();
}

/// Loads every font declared in the bundled `FontManifest.json` — crucially
/// `MaterialIcons` (and CupertinoIcons) — so icon glyphs render as real icons
/// in the goldens instead of tofu boxes.
Future<void> _loadBundledFonts() async {
  try {
    final manifest = json.decode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List<dynamic>;
    for (final entry in manifest) {
      final family = entry['family'] as String;
      final loader = FontLoader(family);
      for (final font in (entry['fonts'] as List<dynamic>)) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  } catch (_) {
    // No manifest / no bundled fonts — icons degrade to boxes but tests run.
  }
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _loadBundledFonts();
  await _loadRealTextFont();
  await testMain();
}
