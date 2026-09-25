// Turning an article into passages worth reading, best fit first.
//
// A whole article is too long for a 15-minute session and too uneven to rate
// as one thing: a hard article can still hold a paragraph at the learner's
// level. So articles are cut into passages, each measured on its own.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/reading_passages.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';

String words(int n, [String word = 'word']) =>
    List.filled(n, word).join(' ');

void main() {
  group('cutting an article into passages', () {
    test('short paragraphs are joined until a passage is long enough', () {
      final text = [
        '${words(50)}.',
        '${words(50)}.',
        '${words(50)}.',
      ].join('\n');

      final passages = splitPassages(text);

      expect(passages, hasLength(1));
      expect(passages.single.text.split(RegExp(r'\s+')), hasLength(150));
    });

    test('a passage closes before it grows past the maximum', () {
      final text = List.filled(6, '${words(100)}.').join('\n');

      final passages = splitPassages(text);

      expect(passages, hasLength(3));
      for (final passage in passages) {
        expect(passage.wordCount, lessThanOrEqualTo(kPassageMaxWords));
      }
    });

    test('one paragraph longer than the maximum is cut at sentences', () {
      final sentence = '${words(30)}.';
      final text = List.filled(12, sentence).join(' ');

      final passages = splitPassages(text);

      expect(passages.length, greaterThan(1));
      for (final passage in passages) {
        expect(passage.wordCount, lessThanOrEqualTo(kPassageMaxWords));
        expect(passage.text, endsWith('.'));
      }
    });

    test('section headings become the passage section, not its text', () {
      final text = '== History ==\n${words(130)}.';

      final passage = splitPassages(text).single;

      expect(passage.section, 'History');
      expect(passage.text, isNot(contains('==')));
    });

    test('reference sections at the end are dropped', () {
      final text = [
        '${words(130)}.',
        '== References ==',
        '${words(130, 'cite')}.',
        '== Other websites ==',
        '${words(130, 'link')}.',
      ].join('\n');

      final passages = splitPassages(text);

      expect(passages, hasLength(1));
      expect(passages.single.text, isNot(contains('cite')));
    });

    test('a leftover too short to read on its own is dropped', () {
      final text = '${words(130)}.\n== End ==\n${words(20)}.';

      expect(splitPassages(text), hasLength(1));
    });
  });

  group('ordering passages for the learner', () {
    final index = WordIndex(const VocabBank(
      bands: [
        ['the', 'go', 'to', 'river'],
        ['bridge'],
      ],
      pseudowords: [],
    ));

    /// A passage whose coverage (bands [1, 0]) is exactly [known] out of 100.
    Passage passage(int known) => Passage(
          text: '${[...List.filled(known, 'river'), ...List.filled(100 - known, 'bridge')].join(' ')}.',
          section: '',
        );

    test('at-level passages come first, closest to the middle of the range',
        () {
      final ranked = rankPassages(
        [passage(90), passage(99), passage(95), passage(97)],
        index,
        knownByBand: const [1.0, 0.0],
        minWords: 0,
      );

      expect([for (final r in ranked) (r.report.coverage * 100).round()],
          [97, 95, 99, 90]);
    });

    test('hard passages keep an order: the least hard first', () {
      final ranked = rankPassages(
        [passage(70), passage(90), passage(80)],
        index,
        knownByBand: const [1.0, 0.0],
        minWords: 0,
      );

      expect([for (final r in ranked) (r.report.coverage * 100).round()],
          [90, 80, 70]);
    });

    test('a passage with too few real words is not offered', () {
      final ranked = rankPassages(
        [const Passage(text: 'The river.', section: '')],
        index,
        knownByBand: const [1.0, 0.0],
      );

      expect(ranked, isEmpty);
    });
  });

  group('what there is to read, per goal', () {
    test('every goal has enough articles to rotate through', () {
      for (final goal in EnglishGoal.values) {
        expect(readingCatalog[goal]!.length, greaterThanOrEqualTo(8),
            reason: goal.name);
      }
    });

    test('no article is listed twice', () {
      for (final goal in EnglishGoal.values) {
        final keys = [
          for (final a in readingCatalog[goal]!) '${a.site}/${a.title}',
        ];
        expect(keys.toSet(), hasLength(keys.length), reason: goal.name);
      }
    });

    test('every source says what license it comes under', () {
      for (final goal in EnglishGoal.values) {
        for (final article in readingCatalog[goal]!) {
          expect(article.license, isNotEmpty);
        }
      }
    });
  });
}
