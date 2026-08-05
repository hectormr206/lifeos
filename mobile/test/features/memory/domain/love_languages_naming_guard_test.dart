// Guards the ONE line that must not be crossed by accident.
//
// The idea behind the couple observation is widely discussed and not owned by
// anyone; copyright protects expression, not ideas or systems. The TITLE of the
// book that popularised it, however, is a trademark — and the way a project
// like this gets into trouble is not by reasoning about copyright, it is by
// someone reaching for the "obvious" label when naming a screen, a settings
// row, a release note or a store listing.
//
// So the rule is mechanical rather than a matter of judgement: the trademarked
// phrase never appears in anything the user can read. The descriptive category
// names ("actos de servicio", "tiempo de calidad") stay — those are ordinary
// Spanish, used to describe what was matched.
//
// This test fails loudly the day someone adds it, which is the whole point: a
// convention nobody enforces is a convention that lasts until the next commit.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/love_languages.dart';

/// The trademarked title, in the shapes it would realistically be typed.
const List<String> _forbidden = [
  'love language',
  'lenguaje del amor',
  'lenguajes del amor',
  '5 lenguajes',
  'cinco lenguajes',
  'five love',
];

bool _mentions(String haystack) {
  final lower = haystack.toLowerCase();
  return _forbidden.any(lower.contains);
}

void main() {
  test('the observation the user reads never names the trademark', () {
    final observation = const LoveLanguageObservation(
      userGivesMost: LoveLanguage.actsOfService,
      partnerValuesMost: LoveLanguage.qualityTime,
    ).describe();

    expect(_mentions(observation), isFalse, reason: observation);
    // ...while still saying the useful, descriptive thing.
    expect(observation, contains('actos de servicio'));
    expect(observation, contains('tiempo de calidad'));
  });

  test('no category name carries the trademark', () {
    for (final name in loveLanguageNames.values) {
      expect(_mentions(name), isFalse, reason: name);
    }
  });

  test('no translated string anywhere in the app names it', () {
    // Every user-facing string the app ships lives in the ARB files. If the
    // phrase is going to appear on a screen, it appears here first.
    final arbs = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.arb'));

    expect(arbs, isNotEmpty, reason: 'l10n files not found — guard cannot run');

    for (final file in arbs) {
      final content = file.readAsStringSync();
      expect(_mentions(content), isFalse,
          reason: '${file.path} names the trademarked title in user-facing copy');
    }
  });

  test('the entry type the user taps is named neutrally', () {
    // "Pareja" describes what it is for. Naming it after the book would make
    // the app look like an official companion to it, which it is not.
    final config = File('lib/features/domains/domain/local_entry_config.dart').readAsStringSync();
    final labels = RegExp(r"label: '([^']+)'").allMatches(config).map((m) => m.group(1)!);

    for (final label in labels) {
      expect(_mentions(label), isFalse, reason: label);
    }
  });
}
