// Guards the app's VOICE against the assumption that it runs on a phone.
//
// LifeOS ships as an Android app on the user's Pixel AND as an installed Linux
// desktop app (/opt/lifeos). The ARB files are shared by both builds, so any
// translatable string that names a phone or a laptop is FALSE on one of them.
//
// The rule this encodes: prefer device-neutral wording ("este dispositivo")
// wherever the sentence is true either way, and reserve platform-conditional
// text for the cases where the meaning genuinely differs — those belong in a
// predicate in `core/platform/app_platform.dart`, not in a shared string.
//
// This is a copy test, not a style test: it fails the build when someone
// reintroduces "en tu teléfono" into a string both platforms render.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hardware nouns a shared, translatable string must never contain.
final _hardwareWords = RegExp(
  r'tel[eé]fono|celular|m[oó]vil\b|laptop|\bphone\b|smartphone',
  caseSensitive: false,
);

Map<String, dynamic> _arb(String path) {
  final file = File(path);
  // Fail loudly rather than silently passing on a moved/renamed file — a
  // guard that cannot run must not look like a guard that passed.
  expect(file.existsSync(), isTrue, reason: 'missing ARB file: $path');
  return json.decode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  for (final path in ['lib/l10n/app_es.arb', 'lib/l10n/app_en.arb']) {
    test('$path has no hardware-specific words in any translatable string', () {
      final arb = _arb(path);
      final offenders = <String, String>{};

      arb.forEach((key, value) {
        // '@'-prefixed entries are translator metadata (descriptions), not
        // strings the user ever sees — they may discuss the laptop freely.
        if (key.startsWith('@')) return;
        if (value is! String) return;
        if (_hardwareWords.hasMatch(value)) offenders[key] = value;
      });

      expect(
        offenders,
        isEmpty,
        reason: 'These strings render on BOTH the Pixel and the Linux desktop '
            'build, so naming the hardware makes them false on one of them. '
            'Use device-neutral wording, or move the difference into a '
            'platform predicate in core/platform/app_platform.dart.',
      );
    });
  }

  test('the two ARB files declare the same keys', () {
    // A key added to only one locale silently falls back to the template, so a
    // half-done neutrality sweep would otherwise pass this file's other test.
    final es = _arb('lib/l10n/app_es.arb').keys.where((k) => !k.startsWith('@')).toSet();
    final en = _arb('lib/l10n/app_en.arb').keys.where((k) => !k.startsWith('@')).toSet();

    expect(es.difference(en), isEmpty, reason: 'keys missing from app_en.arb');
    expect(en.difference(es), isEmpty, reason: 'keys missing from app_es.arb');
  });

  test('the neutral tab labels are present in both locales', () {
    // The specific strings this sweep introduced, pinned so a future edit that
    // reverts them to "En este teléfono" / "Desde tu laptop" fails here too.
    final es = _arb('lib/l10n/app_es.arb');
    final en = _arb('lib/l10n/app_en.arb');

    expect(es['domainTabLocal'], 'En este dispositivo');
    expect(es['domainTabEngine'], 'Desde el motor Axi');
    expect(en['domainTabLocal'], 'On this device');
    expect(en['domainTabEngine'], 'From the Axi engine');
  });
}
