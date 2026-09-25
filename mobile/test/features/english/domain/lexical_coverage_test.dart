// How much of a text the learner already knows.
//
// Reading only teaches when almost every word is known: Hu & Nation (2000)
// found adequate unassisted comprehension needs about 98% of the running words,
// and around 95% is the floor even with help. So before a text is offered, it
// is measured against the learner's own placement.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';

void main() {
  final bank = VocabBank(
    bands: [
      ['the', 'go', 'to', 'run', 'make', 'company', 'stop', 'child', 'be', 'good',
        'and', 'use', 'they', 'not', 'do', 'city', 'big', 'is', 'become', 'can',
        'am', 'work'],
      ['river', 'bridge', 'fish', 'wolf', 'knife', 'behavior', 'color',
        'organize', 'center'],
    ],
    pseudowords: const [],
  );
  final index = WordIndex(bank);

  group('finding the word behind its form', () {
    final cases = {
      'running': 'run',
      'runs': 'run',
      'stopped': 'stop',
      'making': 'make',
      'used': 'use',
      'companies': 'company',
      'went': 'go',
      'children': 'child',
      'was': 'be',
      'rivers': 'river',
      'fished': 'fish',
      // Misses found by running real texts (Simple English Wikipedia,
      // Wikivoyage, a tech blog) through the real word bank:
      'going': 'go',
      'using': 'use',
      'doing': 'do',
      'became': 'become',
      'wolves': 'wolf',
      'knives': 'knife',
      'behaviour': 'behavior',
      'colour': 'color',
      'organise': 'organize',
      'centre': 'center',
    };
    cases.forEach((form, lemma) {
      test('$form → $lemma', () => expect(index.lemmaOf(form), lemma));
    });

    test('a word that is itself in the bank is not bent into another', () {
      expect(index.lemmaOf('is'), 'is');
    });

    test('a word the bank does not have has no lemma', () {
      expect(index.lemmaOf('photosynthesis'), isNull);
    });
  });

  group('reading the words of a text', () {
    test('names are not vocabulary: nobody has to "know" Maria', () {
      expect(contentWords('Then Maria went to Paris.'), ['then', 'went', 'to']);
    });

    test('a capital at the start of a sentence is not a name', () {
      expect(contentWords('The river. Big fish!'), ['the', 'river', 'big', 'fish']);
    });

    test('contractions are read as their words', () {
      expect(contentWords("They don't stop."), ['they', 'do', 'not', 'stop']);
    });

    test('numbers and symbols are not words', () {
      expect(contentWords('3 big rivers, 42%!'), ['big', 'rivers']);
    });

    test('letters glued to a number are a unit, not a word', () {
      expect(contentWords('The 20th river, 5km, the 1990s, 1m tokens.'),
          ['the', 'river', 'the', 'tokens']);
    });

    test('a decimal point does not start a sentence', () {
      // A price table read "$0.10/M" as a new sentence starting with "M".
      expect(contentWords('It is \$0.10/M and \$2/M now.'),
          ['it', 'is', 'and', 'now']);
    });

    test('a unit after a number is not a word, even with a space', () {
      expect(contentWords('It is 5 km and 3 ft from the city.'),
          ['it', 'is', 'and', 'from', 'the', 'city']);
    });

    test('an accented name stays one name, and is left out', () {
      expect(contentWords('They go to México City.'), ['they', 'go', 'to']);
    });

    test('"I" is always a capital and never a name', () {
      expect(contentWords("Now I work. Then I'm big."),
          ['now', 'i', 'work', 'then', 'i', 'am', 'big']);
    });

    test('"cannot" is two words', () {
      expect(contentWords('They cannot stop.'), ['they', 'can', 'not', 'stop']);
    });
  });

  group('measuring a text against a placement', () {
    test('every word in a fully known band is covered', () {
      final report = measureCoverage(
        'The children go to the river.',
        index,
        knownByBand: const [1.0, 1.0],
      );

      expect(report.words, 6);
      expect(report.coverage, closeTo(1.0, 1e-9));
      expect(report.unknownLemmas, isEmpty);
    });

    test('words from an unknown band lower the coverage', () {
      final report = measureCoverage(
        'The children go to the river.',
        index,
        knownByBand: const [1.0, 0.0],
      );

      expect(report.coverage, closeTo(5 / 6, 1e-9));
      expect(report.unknownLemmas, ['river']);
    });

    test('a word the bank does not have counts as unknown', () {
      final report = measureCoverage(
        'The photosynthesis.',
        index,
        knownByBand: const [1.0, 1.0],
      );

      expect(report.coverage, closeTo(0.5, 1e-9));
      expect(report.unknownLemmas, ['photosynthesis']);
    });

    test('unknown words come most repeated first: those are worth learning',
        () {
      final report = measureCoverage(
        'A fish and a bridge. The fish, the fish.',
        index,
        knownByBand: const [1.0, 0.0],
      );

      expect(report.unknownLemmas, ['fish', 'bridge']);
    });

    test('bands the placement never reached count as unknown', () {
      final report = measureCoverage(
        'The river.',
        index,
        knownByBand: const [1.0],
      );

      expect(report.coverage, closeTo(0.5, 1e-9));
    });

    test('"a" and "I" are known by anyone who placed at all', () {
      // The bank has no one-letter words (they would be silly test items),
      // but they are the most frequent words there are.
      final report = measureCoverage('I go to a city.', index,
          knownByBand: const [1.0]);

      expect(report.coverage, closeTo(1.0, 1e-9));
    });

    test('a text with no words has nothing to measure', () {
      final report = measureCoverage('42 — 7%', index, knownByBand: const [1.0]);

      expect(report.words, 0);
      expect(report.fit, TextFit.empty);
    });
  });

  group('how a text fits the learner', () {
    TextFit fit(double coverage) => fitFor(coverage);

    test('98% or more is easy: reading for fluency', () {
      expect(fit(0.99), TextFit.easy);
    });

    test('between 95% and 98% is right at their level', () {
      expect(fit(0.96), TextFit.atLevel);
      expect(fit(0.95), TextFit.atLevel);
    });

    test('under 95% is too hard to learn from, even with help', () {
      expect(fit(0.94), TextFit.hard);
    });
  });
}
