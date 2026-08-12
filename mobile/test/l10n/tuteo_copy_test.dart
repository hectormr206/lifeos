// Guards the app's UI copy against MIXED second-person address.
//
// LifeOS ships to more than one Spanish-speaking country, and most of the app
// already addresses the reader with TUTEO ("toca", "revisa", "quieres"). A
// handful of strings had drifted into VOSEO ("tocá", "revisá", "querés"), which
// reads as a different app talking — and, worse, reads as regional when the
// product is not.
//
// The rule this encodes: UI copy uses neutral-professional TUTEO. This is about
// the INTERFACE's voice only. It deliberately does NOT constrain the
// assistant's conversational voice (what Axi says in chat, the model prompts,
// or the on-device generated text), which is a separate product decision and
// lives outside these files.
//
// SCOPE AND ITS LIMIT. This scans the ARB files (the house source of truth for
// UI strings) and the hardcoded Spanish literals still living in `lib/`, which
// is where the worst offenders actually were.
//
// The detector is a DENYLIST of unambiguous voseo forms, not a general
// conjugation parser, and that is deliberate:
//   * a generic "ends in a stressed vowel" rule false-positives on ordinary
//     Spanish the app needs — future tense ("podrás", "tardará"), third person
//     ("está", "falló"), and plain words ("más", "así", "Inglés");
//   * the voseo imperatives ending in -í ("escribí", "elegí", "pedí") are
//     spelled IDENTICALLY to the first-person preterite ("le escribí" = "I
//     wrote to him"), which `lib/features/memory/domain/love_languages.dart`
//     legitimately contains as keyword data;
//   * a voseo imperative that swallowed an enclitic pronoun loses its written
//     accent ("anotala"), while its tuteo twin GAINS one ("anótala") — telling
//     those apart needs the stress rules, not a word list.
// So -í imperatives and enclitic forms are NOT auto-detected; they were fixed
// by hand. An honest partial guard that nobody has to disable beats a total one
// full of false alarms.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Spanish letters. Dart's `\w` and `\b` are ASCII-only, so an accented vowel
/// counts as a word BOUNDARY — `\brecordá\b` happily matches INSIDE
/// "Recordármelo" (an infinitive, and perfectly good tuteo). Every boundary
/// here is therefore an explicit lookaround over this class, never `\b`.
const _letter = r'A-Za-zÀ-ÿ';

/// Unambiguous voseo stems: the pronouns, plus the -á/-é imperatives and
/// -ás/-és present-indicative forms that have no other reading in Spanish.
///
/// Extend this list when a new one slips in — do not relax it.
const _voseoStems = 'vos|sos'
    // present indicative: -ás / -és
    '|pod[eé]s|ten[eé]s|quer[eé]s|sab[eé]s|conoc[eé]s|olvid[aá]s|necesit[aá]s'
    '|and[aá]s|habl[aá]s|pens[aá]s|hac[eé]s|dec[ií]s|ven[ií]s'
    // imperatives carrying the stress accent
    '|habl[aá]|toc[aá]|revis[aá]|prob[aá]|configur[aá]|activ[aá]|guard[aá]'
    '|busc[aá]|agreg[aá]|envi[aá]|us[aá]|volv[eé]|cerr[aá]|cre[aá]|empez[aá]'
    '|actualiz[aá]|instal[aá]|descarg[aá]|esper[aá]|intent[aá]|verific[aá]'
    '|confirm[aá]|conect[aá]|emparej[aá]|sincroniz[aá]|dej[aá]|cont[aá]'
    '|marc[aá]|reintent[aá]|copi[aá]|peg[aá]|borr[aá]|elimin[aá]|edit[aá]'
    '|ajust[aá]|tom[aá]|mir[aá]|pon[eé]|presion[aá]|reinici[aá]|anot[aá]'
    '|seleccion[aá]|record[aá]|pregunt[aá]|manten[eé]';

final _voseo = RegExp(
  '(?<![$_letter])($_voseoStems)(?![$_letter])',
  caseSensitive: false,
);

Iterable<String> _voseoHits(String text) sync* {
  for (final m in _voseo.allMatches(text)) {
    final word = m.group(0)!;
    // The pronouns carry no accent but are unmistakable.
    if (RegExp(r'^(vos|sos)$', caseSensitive: false).hasMatch(word)) {
      yield word;
      continue;
    }
    // For the verbs, only the ACCENTED spelling is certainly voseo —
    // "toca"/"habla" without the accent is exactly the tuteo we want.
    if (!RegExp(r'[áéí]').hasMatch(word)) continue;
    yield word;
  }
}

void main() {
  group('ARB UI copy is tuteo, never voseo', () {
    for (final path in ['lib/l10n/app_es.arb', 'lib/l10n/app_en.arb']) {
      test('$path has no voseo verb forms', () {
        final file = File(path);
        // A guard that cannot run must fail loudly, never pass quietly.
        expect(file.existsSync(), isTrue, reason: 'missing ARB file: $path');
        final arb = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

        final offenders = <String, String>{};
        arb.forEach((key, value) {
          if (key.startsWith('@')) return; // translator metadata, never shown
          if (value is! String) return;
          final hits = _voseoHits(value).toList();
          if (hits.isNotEmpty) offenders[key] = '${hits.join(", ")}  ->  $value';
        });

        expect(
          offenders,
          isEmpty,
          reason: 'These UI strings address the reader with voseo. The app '
              'ships to more than one country and the rest of the interface '
              'uses tuteo, so mixing the two reads as two different products. '
              'Rewrite in tuteo (toca / revisa / quieres). This constrains the '
              "INTERFACE only, never Axi's conversational voice.",
        );
      });
    }
  });

  test('hardcoded Spanish UI literals in lib/ are tuteo too', () {
    // The ARB files are the house rule, but a real sweep has to cover the
    // literals that never made it into them — that is where "vos conocés" and
    // "Anotala" actually lived.
    final offenders = <String, List<String>>{};

    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        // Generated localization output mirrors the ARB files, already covered
        // above; scanning it would double-report every fix.
        .where((f) => !f.path.contains('app_localizations'));

    for (final file in dartFiles) {
      final hits = <String>[];
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Comments are prose for maintainers, not UI copy.
        if (line.trimLeft().startsWith('//')) continue;
        if (line.trimLeft().startsWith('///')) continue;
        for (final hit in _voseoHits(line)) {
          hits.add('${i + 1}: $hit');
        }
      }
      if (hits.isNotEmpty) offenders[file.path] = hits;
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Hardcoded Spanish UI copy still uses voseo. Rewrite in tuteo. '
          '(New strings belong in the ARB files, not in a literal.)',
    );
  });
}
