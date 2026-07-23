// Golden-test bootstrap (applies to every test under test/goldens/).
//
// flutter_test ships NO real Latin text font, so by default golden PNGs render
// text as opaque boxes — useless for a human to inspect. Here we load a real
// system sans-serif (DejaVu/Liberation/Noto, whichever the host has) under the
// family name `Roboto`, which the golden MaterialApps set as their default
// fontFamily. Result: the deliverable PNGs show READABLE text.
//
// Purely a HOST-side convenience for this verification harness — it never ships
// and touches no production code. If no system font is found the tests still
// run (text just falls back to boxes) so the harness never hard-fails on a
// machine without these fonts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Candidate host font files, in preference order (Regular first, then Bold so
/// bold weights also resolve to a real glyph).
const _regularCandidates = <String>[
  '/usr/share/fonts/TTF/DejaVuSans.ttf',
  '/usr/share/fonts/liberation/LiberationSans-Regular.ttf',
  '/usr/share/fonts/noto/NotoSans-Regular.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
];

const _boldCandidates = <String>[
  '/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
  '/usr/share/fonts/liberation/LiberationSans-Bold.ttf',
  '/usr/share/fonts/noto/NotoSans-Bold.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
  '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
];

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

Future<void> _loadRealTextFont() async {
  final regular = _firstExisting(_regularCandidates);
  if (regular == null) return; // No host font — degrade to boxed glyphs.
  final bold = _firstExisting(_boldCandidates) ?? regular;

  // Register under the family names the golden screens actually request so all
  // text (theme text styles default to `Roboto`) resolves to a real glyph.
  for (final family in const ['Roboto']) {
    final loader = FontLoader(family)
      ..addFont(
          Future.value(File(regular).readAsBytesSync().buffer.asByteData()))
      ..addFont(Future.value(File(bold).readAsBytesSync().buffer.asByteData()));
    await loader.load();
  }
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
