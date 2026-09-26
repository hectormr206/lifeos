// Running a yes/no vocabulary placement.
//
// Bands go from the most frequent words to the rarest, with invented words
// mixed in. The test stops once two bands in a row are mostly unknown: past
// that point every extra word is a "no" that costs the learner patience and
// tells us nothing new.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';

void main() {
  VocabBank bank({int bands = 8, int wordsPerBand = 20, int pseudo = 200}) =>
      VocabBank(
        bands: [
          for (var b = 0; b < bands; b++)
            [for (var i = 0; i < wordsPerBand; i++) 'b${b}w$i'],
        ],
        pseudowords: [for (var i = 0; i < pseudo; i++) 'p$i'],
      );

  /// Answers every item with [knows] until the session ends, and returns the
  /// items in the order they were shown.
  List<PlacementItem> run(
    VocabPlacementSession session,
    bool Function(PlacementItem item) knows,
  ) {
    final shown = <PlacementItem>[];
    while (!session.isFinished) {
      final item = session.current!;
      shown.add(item);
      session.answer(knows: knows(item));
    }
    return shown;
  }

  bool honest(PlacementItem item, {required int knownBands}) =>
      !item.isPseudoword && item.band! < knownBands;

  group('what the learner sees', () {
    test('bands go from the most frequent words to the rarest', () {
      final shown = run(
        VocabPlacementSession(bank(), random: Random(1)),
        (item) => honest(item, knownBands: 8),
      );

      final bands = [
        for (final item in shown)
          if (!item.isPseudoword) item.band!,
      ];
      expect(bands, orderedEquals([...bands]..sort()));
    });

    test('each band shows its sample of real words, without repeats', () {
      final shown = run(
        VocabPlacementSession(bank(), random: Random(2)),
        (item) => honest(item, knownBands: 8),
      );

      final words = [
        for (final item in shown)
          if (!item.isPseudoword) item.text,
      ];
      expect(words.toSet().length, words.length);
      expect(words.length, 8 * kPlacementWordsPerBand);
    });

    test('about one invented word for every three real ones', () {
      final session = VocabPlacementSession(bank(), random: Random(3));
      run(session, (item) => honest(item, knownBands: 8));

      expect(session.tallies.pseudoShown,
          8 * (kPlacementWordsPerBand ~/ kRealWordsPerPseudoword));
    });

    test('an invented word is never shown twice', () {
      final shown = run(
        VocabPlacementSession(bank(), random: Random(4)),
        (item) => honest(item, knownBands: 8),
      );

      final pseudo = [
        for (final item in shown)
          if (item.isPseudoword) item.text,
      ];
      expect(pseudo.toSet().length, pseudo.length);
    });

    test('the same seed gives the same test', () {
      List<String> texts(int seed) => [
            for (final item in run(
              VocabPlacementSession(bank(), random: Random(seed)),
              (item) => honest(item, knownBands: 3),
            ))
              item.text,
          ];

      expect(texts(7), texts(7));
    });
  });

  group('when the test ends', () {
    test('someone who knows every band goes through all of them', () {
      final session = VocabPlacementSession(bank(), random: Random(5));
      run(session, (item) => honest(item, knownBands: 8));

      expect(session.tallies.bands, hasLength(8));
    });

    test('someone who knows nothing stops after two bands', () {
      final session = VocabPlacementSession(bank(), random: Random(6));
      run(session, (item) => false);

      expect(session.tallies.bands, hasLength(2));
    });

    test('it stops two bands after knowledge runs out', () {
      final session = VocabPlacementSession(bank(), random: Random(7));
      run(session, (item) => honest(item, knownBands: 3));

      expect(session.tallies.bands, hasLength(5));
    });

    test('one weak band followed by a strong one does not end it', () {
      final session = VocabPlacementSession(bank(), random: Random(8));
      run(
        session,
        (item) => !item.isPseudoword && item.band != 1,
      );

      expect(session.tallies.bands, hasLength(8));
    });

    test('answering after the end is a mistake, not a silent no-op', () {
      final session = VocabPlacementSession(bank(bands: 1), random: Random(9));
      run(session, (item) => true);

      expect(() => session.answer(knows: true), throwsStateError);
    });
  });

  test('a strong, honest learner is placed at C2 with a reliable result', () {
    final session = VocabPlacementSession(bank(), random: Random(10));
    run(session, (item) => honest(item, knownBands: 8));

    final result = scoreVocabPlacement(session.tallies);
    expect(result.cefr, CefrLevel.c2);
    expect(result.estimatedWords, 8000);
    expect(result.reliable, isTrue);
  });
}
