// Scoring a yes/no vocabulary placement.
//
// The learner sees real words, ranked by frequency in bands of a thousand, and
// invented words that look real. Each "I know it" on an invented word is a
// guess we can see, so the band scores are corrected by that guessing rate
// before anything is claimed about the learner's level.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

void main() {
  PlacementTallies tallies(
    List<double> hitRates, {
    int perBand = 10,
    int pseudoShown = 10,
    int pseudoYes = 0,
  }) =>
      PlacementTallies(
        bands: [
          for (final rate in hitRates)
            BandTally(shown: perBand, yes: (rate * perBand).round()),
        ],
        pseudoShown: pseudoShown,
        pseudoYes: pseudoYes,
      );

  group('correcting for guessing', () {
    test('with no false alarms the hit rate stands', () {
      expect(correctedKnownRate(0.8, 0), closeTo(0.8, 1e-9));
    });

    test('false alarms discount the hit rate', () {
      // (0.8 - 0.2) / (1 - 0.2)
      expect(correctedKnownRate(0.8, 0.2), closeTo(0.75, 1e-9));
    });

    test('never goes below zero when guessing beats knowing', () {
      expect(correctedKnownRate(0.3, 0.5), 0);
    });

    test('saying yes to every invented word leaves nothing to trust', () {
      expect(correctedKnownRate(1, 1), 0);
    });
  });

  group('mapping to CEFR (Milton & Alexiou 2009, English X-Lex)', () {
    final cases = <int, CefrLevel>{
      0: CefrLevel.a1,
      1499: CefrLevel.a1,
      1500: CefrLevel.a2,
      2500: CefrLevel.a2,
      // The published table leaves 2500-2750 unassigned. It stays A2: a level
      // is claimed only once its lower bound is reached.
      2749: CefrLevel.a2,
      2750: CefrLevel.b1,
      3249: CefrLevel.b1,
      3250: CefrLevel.b2,
      3749: CefrLevel.b2,
      3750: CefrLevel.c1,
      4499: CefrLevel.c1,
      4500: CefrLevel.c2,
      5000: CefrLevel.c2,
    };
    cases.forEach((score, level) {
      test('$score words → ${level.name}', () {
        expect(cefrForXlexScore(score), level);
      });
    });
  });

  group('scoring a placement', () {
    test('an honest learner with falling knowledge per band', () {
      final result = scoreVocabPlacement(
        tallies([1.0, 0.9, 0.7, 0.5, 0.3]),
      );

      expect(result.xlexScore, 3400);
      expect(result.estimatedWords, 3400);
      expect(result.cefr, CefrLevel.b2);
      expect(result.reliable, isTrue);
    });

    test('the CEFR score only counts the 5000 most frequent words', () {
      final result = scoreVocabPlacement(
        tallies(List.filled(8, 1.0)),
      );

      expect(result.xlexScore, 5000);
      expect(result.estimatedWords, 8000);
      expect(result.cefr, CefrLevel.c2);
    });

    test('bands the test never reached count as unknown', () {
      final result = scoreVocabPlacement(tallies([1.0, 1.0]));

      expect(result.xlexScore, 2000);
      expect(result.cefr, CefrLevel.a2);
    });

    test('guessing is subtracted before the level is claimed', () {
      // 2 of 10 invented words "known": every band is discounted.
      final result = scoreVocabPlacement(
        tallies([1.0, 1.0, 1.0, 0.6, 0.2], pseudoYes: 2),
      );

      expect(result.falseAlarmRate, closeTo(0.2, 1e-9));
      expect(result.knownByBand[3], closeTo(0.5, 1e-9));
      expect(result.knownByBand[4], 0);
      expect(result.xlexScore, 3500);
    });
  });

  group('knowing when not to trust the result', () {
    test('someone who says yes to everything is not placed at C2', () {
      final result = scoreVocabPlacement(
        tallies(List.filled(5, 1.0), pseudoYes: 10),
      );

      expect(result.estimatedWords, 0);
      expect(result.reliable, isFalse);
    });

    test('too many false alarms make the result unreliable', () {
      final result = scoreVocabPlacement(
        tallies(List.filled(5, 1.0), pseudoYes: 4),
      );

      expect(result.reliable, isFalse);
    });

    test('too few invented words shown cannot measure guessing', () {
      final result = scoreVocabPlacement(
        tallies([1.0, 1.0], pseudoShown: 3),
      );

      expect(result.reliable, isFalse);
    });

    test('a band that showed no words adds nothing', () {
      final result = scoreVocabPlacement(
        const PlacementTallies(
          bands: [BandTally(shown: 10, yes: 10), BandTally(shown: 0, yes: 0)],
          pseudoShown: 10,
          pseudoYes: 0,
        ),
      );

      expect(result.estimatedWords, 1000);
    });
  });
}
